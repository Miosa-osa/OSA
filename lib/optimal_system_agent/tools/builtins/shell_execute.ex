defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  @max_output_bytes 102_400
  @default_timeout_ms 300_000

  @impl true
  def safety, do: :terminal

  @impl true
  def name, do: "shell_execute"

  @impl true
  def description, do: "Execute a shell command safely"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "Shell command to execute"},
        "cwd" => %{"type" => "string", "description" => "Working directory for the command. Optional; defaults to ~/.osa/workspace."}
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = params) when is_binary(command) do
    # Strip trailing & (background operator) to force foreground execution
    command = Regex.replace(~r/\s*&\s*$/, command, "")

    # Strip leading nohup
    command = Regex.replace(~r/^\s*nohup\s+/, command, "")

    trimmed = String.trim(command)

    if trimmed == "" do
      {:error, "Blocked: empty command"}
    else
      case validate_command(trimmed) do
        :ok ->
          workspace = Path.expand("~/.osa/workspace")
          File.mkdir_p(workspace)

          # Resolve working directory: explicit cwd param or default workspace
          effective_cwd =
            case params["cwd"] do
              nil -> workspace
              "" -> workspace
              cwd_path ->
                expanded_cwd = Path.expand(cwd_path)

                if File.dir?(expanded_cwd) do
                  expanded_cwd
                else
                  :invalid
                end
            end

          if effective_cwd == :invalid do
            {:error, "cwd does not exist: #{params["cwd"]}"}
          else
            timeout =
              case System.get_env("OSA_SHELL_TIMEOUT_MS") do
                nil -> @default_timeout_ms
                s -> String.to_integer(s)
              end

            run_command(trimmed, effective_cwd, timeout)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def execute(%{"command" => _}), do: {:error, "command must be a string"}
  def execute(_), do: {:error, "Missing required parameter: command"}

  defp run_command(command, cwd, timeout_ms) do
    task = Task.async(fn ->
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
    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n[output truncated at 100KB]"
    else
      output
    end
  end

  # Blocked command names — matched at word boundaries across pipes, semicolons, && and ||.
  @blocked_commands ~w(
    rm sudo dd mkfs fdisk chmod chown kill killall pkill
    reboot shutdown halt poweroff mount umount
    iptables systemctl passwd useradd userdel
    nc ncat
    env printenv export set declare compgen
  )

  # Download commands with output flags — matched as patterns.
  @download_patterns [
    ~r/\bcurl\b.*(-o|--output)\b/,
    ~r/\bwget\b.*-O\b/
  ]

  # Shell injection patterns.
  @injection_patterns [
    ~r/`/,              # backtick substitution
    ~r/\$\(/,           # $() command substitution
    ~r/\$\{/,           # ${} variable expansion
    ~r/\$[A-Za-z_]\w*/,  # bare $VAR expansion
    ~r/>\s*\/etc\//,    # redirect to /etc/
    ~r/>\s*\/usr\//     # redirect to /usr/
  ]

  # Path traversal / sensitive file patterns.
  @path_patterns [
    ~r/\.\.\//,         # ../ traversal
    ~r/\/etc\//,        # /etc/ access
    ~r/\.ssh\//,        # .ssh/ access
    ~r/\.env/           # .env file access (including .env.backup, .environment, etc.)
  ]

  # /proc environ leak patterns — catches attempts to read env vars via procfs.
  @env_leak_patterns [
    ~r|/proc/\w+/environ|,
    ~r|/proc/self/environ|
  ]

  # cd restriction — only allow cd within ~/.osa/
  @cd_pattern ~r/\bcd\s+(?!~?\/?\.osa)/

  defp validate_command(command) do
    # Split on pipes, semicolons, && and || to check each segment.
    segments =
      command
      |> String.split(~r/\s*[|;&]{1,2}\s*/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with :ok <- check_blocked_commands(segments, command),
         :ok <- check_download_patterns(command),
         :ok <- check_injection_patterns(command),
         :ok <- check_path_patterns(command),
         :ok <- check_env_leak_patterns(command),
         :ok <- check_cd_restriction(command) do
      :ok
    end
  end

  defp check_blocked_commands(segments, _full_command) do
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

      matched = Enum.find(@blocked_commands, fn cmd ->
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
    matched = Enum.find(@download_patterns, &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: download with output flag"}
    else
      :ok
    end
  end

  defp check_injection_patterns(command) do
    matched = Enum.find(@injection_patterns, &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: shell injection"}
    else
      :ok
    end
  end

  defp check_path_patterns(command) do
    matched = Enum.find(@path_patterns, &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: sensitive path access"}
    else
      :ok
    end
  end

  defp check_env_leak_patterns(command) do
    matched = Enum.find(@env_leak_patterns, &Regex.match?(&1, command))

    if matched do
      {:error, "Blocked: blocked pattern matched: /proc environ access"}
    else
      :ok
    end
  end

  defp check_cd_restriction(command) do
    # Check for attempts to cd outside ~/.osa/ via the pattern.
    if Regex.match?(@cd_pattern, command) do
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
end
