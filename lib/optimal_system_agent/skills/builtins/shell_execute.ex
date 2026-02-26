defmodule OptimalSystemAgent.Skills.Builtins.ShellExecute do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @blocked_commands MapSet.new(
    ~w(rm sudo dd mkfs fdisk format shutdown reboot halt poweroff init telinit
       kill killall pkill mount umount iptables systemctl passwd useradd userdel
       nc ncat)
  )

  @blocked_patterns [
    # Privilege escalation
    ~r/\brm\s+(-[a-zA-Z]*\s+)*\//,
    ~r/\bsudo\b/,
    ~r/\bdd\b/,
    ~r/\bmkfs\b/,
    # Output redirection to system paths
    ~r/>\s*\/etc\//,
    ~r/>\s*~\/\.ssh\//,
    ~r/>\s*\/boot\//,
    ~r/>\s*\/usr\//,
    # Shell injection
    ~r/`[^`]*`/,
    ~r/\$\([^)]*\)/,
    ~r/\$\{[^}]*\}/,
    # Chained blocked commands
    ~r/;\s*(rm|sudo|dd|mkfs|shutdown)/,
    ~r/\|\s*(rm|sudo|dd|mkfs|shutdown)/,
    ~r/&&\s*(rm|sudo|dd|mkfs|shutdown)/,
    ~r/\|\|\s*(rm|sudo|dd|mkfs|shutdown)/,
    # Absolute path invocations
    ~r/\/bin\/(rm|dd|mkfs)/,
    ~r/\/usr\/bin\/(sudo|pkill|killall)/,
    # Dangerous permission changes
    ~r/\bchmod\s+[0-7]*777\b/,
    ~r/\bchown\s+root\b/,
    # Sensitive file reads
    ~r/\b(cat|less|more|head|tail|strings|xxd)\s+.*\/etc\/(shadow|passwd|sudoers)/,
    ~r/\b(cat|less|more|head|tail|strings|xxd)\s+.*\.ssh\/(id_rsa|id_ed25519|id_ecdsa|id_dsa)/,
    ~r/\b(cat|less|more|head|tail|strings|xxd)\s+.*\.env\b/,
    # Path traversal
    ~r/\.\.\//,
    # curl/wget output to file
    ~r/\bcurl\b.*\s(-o\s|--output\s)/,
    ~r/\bcurl\b.*\s-[a-zA-Z]*o\s/,
    ~r/\bwget\b.*\s(-O\s|--output-document\s)/,
    ~r/\bwget\b.*\s-[a-zA-Z]*O\s/
  ]

  @max_output_bytes 100_000

  @impl true
  def name, do: "shell_execute"

  @impl true
  def description, do: "Execute a shell command safely"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "Shell command to execute"}
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command}) do
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
          full_command = "cd #{workspace} 2>/dev/null || true; #{trimmed}"

          task =
            Task.async(fn ->
              System.cmd("sh", ["-c", full_command], stderr_to_stdout: true)
            end)

          case Task.yield(task, 30_000) || Task.shutdown(task) do
            {:ok, {output, 0}} -> {:ok, maybe_truncate(output)}
            {:ok, {output, code}} -> {:error, "Exit #{code}:\n#{output}"}
            nil -> {:error, "Command timed out after 30 seconds"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_truncate(output) do
    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n[output truncated at 100KB]"
    else
      output
    end
  end

  defp validate_command(command) do
    # Check cd outside ~/.osa/
    if cd_outside_osa?(command) do
      {:error, "Blocked: cd outside ~/.osa/ is not allowed"}
    else
      # Check blocked commands first (provides specific command name in message)
      segments = Regex.split(~r/[|;&]/, command)

      blocked_segment =
        Enum.find(segments, fn segment ->
          first = segment |> String.trim() |> String.split() |> List.first() |> to_string()
          basename = Path.basename(first)
          MapSet.member?(@blocked_commands, first) or MapSet.member?(@blocked_commands, basename)
        end)

      if blocked_segment do
        {:error, "Command contains blocked command: #{String.trim(blocked_segment)}"}
      else
        # Then check blocked patterns
        if Enum.any?(@blocked_patterns, &Regex.match?(&1, command)) do
          {:error, "Command contains blocked pattern"}
        else
          :ok
        end
      end
    end
  end

  defp cd_outside_osa?(command) do
    # Match any `cd <path>` where path is not under ~/.osa/
    osa_prefix = Path.expand("~/.osa")

    Regex.scan(~r/\bcd\s+(\S+)/, command)
    |> Enum.any?(fn [_match, path] ->
      expanded = Path.expand(path)
      not String.starts_with?(expanded, osa_prefix)
    end)
  end
end
