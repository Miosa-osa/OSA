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
  alias OptimalSystemAgent.Sandbox
  alias OptimalSystemAgent.Shell.BackgroundManager

  # ── Stage 1: Input validation ─────────────────────────────────────────
  #
  # This stage also normalises the command string (strip trailing &,
  # nohup prefix, leading/trailing whitespace) so that check_permissions
  # and execute always receive the clean, trimmed value. Normalisation is
  # cheap and idempotent — safe to do here.

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"command" => command} = input, _ctx) when is_binary(command) do
    raw = String.trim(command)

    cond do
      raw == "" ->
        # Return as a validation error so the adapter preserves the exact message
        # string (validation errors are stripped of code: {:error, msg, code} →
        # {:error, msg}), matching the original direct return of {:error, "Blocked: …"}.
        {:error, "Blocked: empty command", -32_602}

      # Reject an obviously incomplete command that ends with a dangling
      # trailing operator (`&&`, `||`, `|`, or a line-continuation `\`). Left
      # to run, such a command makes the shell wait for the missing right-hand
      # side and can hang until the wall-clock timeout — fail fast instead with
      # an actionable message so the model re-issues a complete command. A lone
      # trailing `&` is NOT rejected here: it is the background operator and is
      # stripped below to force foreground execution.
      dangling_operator?(raw) ->
        {:error,
         "Blocked: command ends with a dangling operator (&&, ||, |, or \\) — " <>
           "re-issue a complete command with a right-hand side.", -32_602}

      true ->
        # Strip trailing & (background operator) to force foreground execution.
        normalised = Regex.replace(~r/\s*&\s*$/, command, "")
        # Strip leading nohup.
        normalised = Regex.replace(~r/^\s*nohup\s+/, normalised, "")
        trimmed = String.trim(normalised)

        if trimmed == "" do
          {:error, "Blocked: empty command", -32_602}
        else
          {:ok, %{input | "command" => trimmed}}
        end
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
  def execute(%{"command" => command} = params, ctx) do
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

    cond do
      effective_cwd == :invalid ->
        {:error, "cwd does not exist: #{params["cwd"]}"}

      # BACKGROUND: spawn a supervised background process and return a
      # background_id immediately. The command still passed through the same
      # validate/check_permissions security pipeline above. Background exec
      # uses the host path only — sandbox routing is not supported here.
      truthy?(params["run_in_background"]) ->
        run_in_background(command, effective_cwd, ctx)

      true ->
        timeout = parse_timeout_ms(System.get_env("OSA_SHELL_TIMEOUT_MS"))

        # SANDBOX ROUTING: when a non-host sandbox backend is configured (or
        # sandbox mode is :required), route the command through Sandbox.Router
        # instead of raw host exec. Default config (no sandbox, :optional mode)
        # keeps the existing host execution path — no behavior change.
        if use_sandbox?() do
          run_in_sandbox(command, effective_cwd, timeout)
        else
          session_id = ctx && Map.get(ctx, :session_id)
          run_command(command, effective_cwd, timeout, session_id)
        end
    end
  end

  @registry OptimalSystemAgent.Shell.ForegroundRegistry

  @doc """
  Promote the foreground `shell_execute` command currently running for
  `session_id` to a supervised background task (TUI Ctrl+B mid-run detach).

  Looks up the process blocked in the foreground receive loop, signals it to
  hand its live OS process off to `BackgroundManager`, and waits briefly for the
  new `background_id`. Returns `{:error, :no_active_command}` when nothing is
  running for the session, or `{:error, :timeout}` if the command finished before
  the hand-off completed.
  """
  @spec detach_foreground(String.t()) ::
          {:ok, String.t()} | {:error, :no_active_command | :timeout | term()}
  def detach_foreground(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        ref = make_ref()
        send(pid, {:detach, self(), ref})

        receive do
          {:detached, ^ref, id} -> {:ok, id}
          {:detach_failed, ^ref, reason} -> {:error, reason}
        after
          3_000 -> {:error, :timeout}
        end

      [] ->
        {:error, :no_active_command}
    end
  end

  def detach_foreground(_), do: {:error, :no_active_command}

  # Resolve the command timeout from OSA_SHELL_TIMEOUT_MS. Pure + defensive so a
  # typo like "30s"/"5000ms"/"" falls back to the default instead of raising
  # ArgumentError before run_command's rescue (which would break EVERY shell call
  # until the env var is fixed). Public so it can be unit-tested without mutating
  # the process-global env (which flakes under parallel test runs).
  @doc false
  def parse_timeout_ms(nil), do: Constants.default_timeout_ms()

  def parse_timeout_ms(s) when is_binary(s) do
    # Require the value to be a bare positive integer (milliseconds). A trailing
    # unit like "30s"/"5000ms" must fall back to the default rather than silently
    # parsing "30s" as 30ms — Integer.parse/1 returns {30, "s"}, so we insist the
    # remainder is empty.
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 ->
        n

      _ ->
        Logger.warning("[shell_execute] invalid OSA_SHELL_TIMEOUT_MS=#{inspect(s)} — using default")
        Constants.default_timeout_ms()
    end
  end

  def parse_timeout_ms(_), do: Constants.default_timeout_ms()

  # True when a trimmed command ends with an incomplete/dangling shell operator:
  #   * `&&` / `||`  — logical connective with no right-hand command
  #   * `|`          — pipe with no downstream command (a lone `|`, not `||`)
  #   * `\`          — a trailing line continuation
  # A single trailing `&` (background operator) is intentionally NOT matched:
  # it is handled by the background-strip in validate/2.
  defp dangling_operator?(cmd) when is_binary(cmd) do
    Regex.match?(~r/(?:&&|\|\|?|\\)\s*$/, cmd)
  end

  # Null device for redirecting a command's stdin so it can never block waiting
  # for interactive input (a key cause of silent multi-minute hangs).
  defp null_device do
    case :os.type() do
      {:win32, _} -> "NUL"
      _ -> "/dev/null"
    end
  end

  # Accept boolean true or the string "true" (some callers stringify args).
  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp run_in_background(command, cwd, ctx) do
    session_id = ctx && Map.get(ctx, :session_id)

    # Ensure a notifier is listening for this parent session BEFORE the worker
    # starts, so a fast command's completion broadcast is never missed (the
    # topic subscription must be live before the worker can exit). This reuses
    # the same re-entry mechanism the background-subagent path uses.
    if is_binary(session_id) do
      OptimalSystemAgent.Agent.BackgroundNotifier.ensure_started(session_id)
    end

    case BackgroundManager.start(command, cwd, session_id: session_id) do
      {:ok, id} ->
        # Announce the new background terminal so the TUI's live count updates.
        if is_binary(session_id) do
          Phoenix.PubSub.broadcast(
            OptimalSystemAgent.PubSub,
            "osa:session:#{session_id}",
            {:osa_event,
             %{
               type: :background_command_started,
               background_id: id,
               command: command,
               session_id: session_id,
               running_count: BackgroundManager.running_count()
             }}
          )
        end

        {:ok,
         "Started background command.\n" <>
           "- background_id: #{id}\n" <>
           "- cwd: #{cwd}\n\n" <>
           "The command is running in the background; you'll be notified automatically " <>
           "when it completes (with its exit code). You can also poll its output and status " <>
           "with the bash_output tool using background_id \"#{id}\". " <>
           "To stop it, call bash_output with kill=true."}

      {:error, reason} ->
        {:error, "Failed to start background command: #{reason}"}
    end
  end

  # Route to the sandbox only when the operator has actually configured one.
  # Host + :optional (the default) stays on the existing host path so nothing
  # changes unless a sandbox backend is selected.
  defp use_sandbox? do
    Sandbox.Router.required?() or Sandbox.Router.backend() != Sandbox.Host
  rescue
    _ -> false
  end

  defp run_in_sandbox(command, cwd, timeout_ms) do
    case Sandbox.Router.execute(command, working_dir: cwd, timeout: timeout_ms) do
      {:ok, output} -> {:ok, maybe_truncate(output)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, "Sandbox execution error: #{Exception.message(e)}"}
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

  defp run_command(command, cwd, timeout_ms, session_id \\ nil) do
    # Spawn via Port (not System.cmd) so that on the timeout path we can kill
    # the underlying OS process — and on Windows its whole tree — instead of
    # only shutting down the BEAM task and leaking an orphaned child.
    sh = OptimalSystemAgent.OS.Shell.executable()
    # Redirect stdin from the null device so no command can block the port
    # waiting for interactive input (EOF is delivered immediately). stderr is
    # merged into stdout so the caller sees a single combined stream.
    args = OptimalSystemAgent.OS.Shell.port_flags() ++ [command <> " 2>&1 < " <> null_device()]

    port =
      Port.open(
        {:spawn_executable, sh},
        [:binary, :exit_status, :hide, {:args, args}, {:cd, cwd}]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    # Register this process so the TUI (Ctrl+B) can find and detach the running
    # command mid-flight. Registration is best-effort: if another foreground
    # command is already registered for the session, this one simply isn't
    # detachable (unique registry) — it still runs normally.
    registered? = register_foreground(session_id)

    detach = %{command: command, cwd: cwd, session_id: session_id}
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect_command_output(port, os_pid, deadline, timeout_ms, [], detach)
    after
      if registered?, do: Registry.unregister(@registry, session_id)
    end
  rescue
    e -> {:error, "Shell execution error: #{Exception.message(e)}"}
  end

  defp register_foreground(session_id) when is_binary(session_id) do
    case Registry.register(@registry, session_id, nil) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp register_foreground(_), do: false

  defp collect_command_output(port, os_pid, deadline, timeout_ms, acc, detach) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_command_output(port, os_pid, deadline, timeout_ms, [data | acc], detach)

      {^port, {:exit_status, 0}} ->
        {:ok, maybe_truncate(collected_output(acc))}

      {^port, {:exit_status, code}} ->
        {:error, "Exit #{code}:\n#{maybe_truncate(collected_output(acc))}"}

      {:detach, reply_to, ref} ->
        handle_detach(port, os_pid, acc, detach, reply_to, ref, deadline, timeout_ms)
    after
      remaining ->
        kill_os_process(os_pid)
        safe_close_port(port)
        {:error, "Command timed out after #{div(timeout_ms, 1000)}s"}
    end
  end

  # Hand the live OS process off to a supervised BackgroundTask, then return a
  # "moved to background" result so the current turn completes. The worker takes
  # over the port (via Port.connect) and later broadcasts a
  # background_command_completed event just like any other background command.
  defp handle_detach(port, os_pid, acc, detach, reply_to, ref, deadline, timeout_ms) do
    session_id = detach.session_id
    output_so_far = collected_output(acc)

    # Ensure a notifier is listening BEFORE the worker can finish, so the
    # completion is injected back into the Loop (mirrors run_in_background/3).
    if is_binary(session_id) do
      OptimalSystemAgent.Agent.BackgroundNotifier.ensure_started(session_id)
    end

    case BackgroundManager.adopt(
           command: detach.command,
           cwd: detach.cwd,
           session_id: session_id,
           port: port,
           os_pid: os_pid,
           initial: output_so_far
         ) do
      {:ok, id, child_pid} ->
        # Transfer port ownership to the worker, then unlink so THIS process
        # exiting can never take the port (and its OS child) down. Finally,
        # forward any port messages already sitting in our mailbox.
        Port.connect(port, child_pid)
        safe_unlink(port)
        forward_pending_port_messages(port, child_pid)
        broadcast_command_started(session_id, id, detach.command)
        send(reply_to, {:detached, ref, id})

        {:ok,
         "Moved to background.\n" <>
           "- background_id: #{id}\n" <>
           "- cwd: #{detach.cwd}\n\n" <>
           "The command keeps running in the background; you'll be notified " <>
           "automatically when it completes (with its exit code). Poll it with " <>
           "the bash_output tool using background_id \"#{id}\", or stop it with kill=true."}

      {:error, reason} ->
        # Adoption failed — keep running in the foreground as if nothing happened.
        send(reply_to, {:detach_failed, ref, reason})
        collect_command_output(port, os_pid, deadline, timeout_ms, acc, detach)
    end
  end

  defp safe_unlink(port) do
    :erlang.unlink(port)
    :ok
  rescue
    _ -> :ok
  end

  # Drain any {port, msg} tuples already delivered to this mailbox (before the
  # ownership transfer) and forward them to the worker, which handles the same
  # {port, {:data,…}} / {port, {:exit_status,…}} shapes.
  defp forward_pending_port_messages(port, child_pid) do
    receive do
      {^port, msg} ->
        send(child_pid, {port, msg})
        forward_pending_port_messages(port, child_pid)
    after
      0 -> :ok
    end
  end

  defp broadcast_command_started(session_id, id, command) when is_binary(session_id) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :background_command_started,
         background_id: id,
         command: command,
         session_id: session_id,
         running_count: BackgroundManager.running_count()
       }}
    )

    :ok
  rescue
    _ -> :ok
  end

  defp broadcast_command_started(_, _, _), do: :ok

  defp collected_output(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    case :os.type() do
      {:win32, _} ->
        _ = System.cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"], stderr_to_stdout: true)

      _ ->
        # SIGTERM for a graceful stop, then SIGKILL as a fallback.
        _ = System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
        _ = System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp safe_close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_truncate(output) do
    max = Constants.max_output_bytes()

    bounded =
      if byte_size(output) > max do
        # max is a BYTE budget; String.slice/3 counts CHARACTERS, so multibyte
        # output could pass ~4x the cap. binary_part keeps the cap honest.
        binary_part(output, 0, max) <> "\n[output truncated at 100KB]"
      else
        output
      end

    # Coerce to valid UTF-8: raw command bytes (e.g. binary blobs) would
    # otherwise break the JSON serialization of the tool result downstream.
    ensure_utf8(bounded)
  end

  defp ensure_utf8(bin) do
    if String.valid?(bin), do: bin, else: IO.iodata_to_binary(scrub_utf8(bin, []))
  end

  defp scrub_utf8(<<>>, acc), do: Enum.reverse(acc)
  defp scrub_utf8(<<c::utf8, rest::binary>>, acc), do: scrub_utf8(rest, [<<c::utf8>> | acc])
  defp scrub_utf8(<<_bad, rest::binary>>, acc), do: scrub_utf8(rest, [<<0xFFFD::utf8>> | acc])
end
