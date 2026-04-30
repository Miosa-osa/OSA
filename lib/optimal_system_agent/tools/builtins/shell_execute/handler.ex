defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `shell_execute`.

  Mirrors the layout of `FileRead.Handler`:
    * `validate/2`            — type-checks input shape (cheap)
    * `check_permissions/2`   — command validation / security deny logic
    * `execute/2`             — actual shell execution

  All validation and execution logic was moved verbatim from the original
  `shell_execute.ex`. No semantic changes — just relocation and the
  validate/check_permissions/execute split.
  """

  require Logger

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────
  #
  # This stage also normalises the command string (strip trailing &,
  # nohup prefix, leading/trailing whitespace) so that check_permissions
  # and execute always receive the clean, trimmed value. Normalisation is
  # cheap and idempotent — safe to do here.

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"command" => command} = input, _ctx) when is_binary(command) do
    # Strip trailing & (background operator) to force foreground execution.
    normalised = Regex.replace(~r/\s*&\s*$/, command, "")
    # Strip leading nohup.
    normalised = Regex.replace(~r/^\s*nohup\s+/, normalised, "")
    trimmed = String.trim(normalised)

    if trimmed == "" do
      # Return as a validation error so the adapter preserves the exact message
      # string (validation errors are stripped of code: {:error, msg, code} →
      # {:error, msg}), matching the original direct return of {:error, "Blocked: …"}.
      {:error, "Blocked: empty command", -32_602}
    else
      {:ok, %{input | "command" => trimmed}}
    end
  end

  def validate(%{"command" => _}, _ctx),
    do: {:error, "command must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: command", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────
  #
  # At this point "command" is already normalised (stripped and trimmed)
  # by validate/2 above.

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"command" => command} = input, _ctx) do
    case validate_command(command) do
      :ok -> {:allow, input}
      {:error, reason} -> {:deny, reason}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"command" => command} = params, _ctx) do
    workspace = Path.expand("~/.osa/workspace")
    File.mkdir_p(workspace)

    effective_cwd =
      case params["cwd"] do
        nil ->
          workspace

        "" ->
          workspace

        cwd_path ->
          expanded_cwd = Path.expand(cwd_path)
          if File.dir?(expanded_cwd), do: expanded_cwd, else: :invalid
      end

    if effective_cwd == :invalid do
      {:error, "cwd does not exist: #{params["cwd"]}"}
    else
      timeout =
        case System.get_env("OSA_SHELL_TIMEOUT_MS") do
          nil -> Constants.default_timeout_ms()
          s -> String.to_integer(s)
        end

      run_command(command, effective_cwd, timeout)
    end
  end

  # ── Private: validation helpers ───────────────────────────────────────

  defp validate_command(command) do
    # Split on pipes, semicolons, && and || to check each segment.
    segments =
      command
      |> String.split(~r/\s*[|;&]{1,2}\s*/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with :ok <- check_blocked_commands(segments),
         :ok <- check_download_patterns(command),
         :ok <- check_injection_patterns(command),
         :ok <- check_path_patterns(command),
         :ok <- check_env_leak_patterns(command),
         :ok <- check_cd_restriction(command) do
      :ok
    end
  end

  defp check_blocked_commands(segments) do
    Enum.reduce_while(segments, :ok, fn segment, :ok ->
      # Extract the first word (the command name) from the segment.
      # Strip leading backslashes to catch \rm -rf style bypass attempts.
      first_word =
        segment
        |> String.split(~r/\s+/, parts: 2)
        |> hd()
        |> String.replace(~r/^\\+/, "")

      # Also check without path prefix (e.g., /usr/bin/rm → rm).
      base_name = Path.basename(first_word)

      matched =
        Enum.find(Constants.blocked_commands(), fn cmd ->
          base_name == cmd or first_word == cmd
        end)

      if matched do
        {:halt, {:error, "Blocked: blocked pattern matched: #{matched}"}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp check_download_patterns(command) do
    matched = Enum.find(Constants.download_patterns(), &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: download with output flag"}
    else
      :ok
    end
  end

  defp check_injection_patterns(command) do
    matched = Enum.find(Constants.injection_patterns(), &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: shell injection"}
    else
      :ok
    end
  end

  defp check_path_patterns(command) do
    matched = Enum.find(Constants.path_patterns(), &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: sensitive path access"}
    else
      :ok
    end
  end

  defp check_env_leak_patterns(command) do
    matched = Enum.find(Constants.env_leak_patterns(), &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: /proc environ access"}
    else
      :ok
    end
  end

  defp check_cd_restriction(command) do
    # Check for attempts to cd outside ~/.osa/ via the pattern.
    if Regex.match?(Constants.cd_pattern(), command) do
      {:error, "Blocked: cd outside ~/.osa/ is not allowed"}
    else
      # Also reject any cd path that contains .. after expansion,
      # to prevent cd ~/.osa/../../etc style traversal.
      osa_root = Path.expand("~/.osa")

      traversal_found =
        Regex.scan(~r/\bcd\s+(\S+)/, command)
        |> Enum.any?(fn [_full, path] ->
          expanded = Path.expand(path)
          not String.starts_with?(expanded, osa_root)
        end)

      if traversal_found do
        {:error, "Blocked: cd path traverses outside ~/.osa/"}
      else
        :ok
      end
    end
  end

  # ── Private: execution ────────────────────────────────────────────────

  defp run_command(command, cwd, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command],
          cd: cwd,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, maybe_truncate(output)}
      {:ok, {output, code}} -> {:error, "Exit #{code}:\n#{maybe_truncate(output)}"}
      nil -> {:error, "Command timed out after #{div(timeout_ms, 1000)}s"}
    end
  rescue
    e -> {:error, "Shell execution error: #{Exception.message(e)}"}
  end

  defp maybe_truncate(output) do
    max = Constants.max_output_bytes()

    if byte_size(output) > max do
      String.slice(output, 0, max) <> "\n[output truncated at 100KB]"
    else
      output
    end
  end
end
