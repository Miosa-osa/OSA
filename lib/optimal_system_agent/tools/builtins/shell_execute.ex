defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  alias OptimalSystemAgent.Sandbox.Executor

  alias OptimalSystemAgent.Security.ShellPolicy

  @max_output_bytes ShellPolicy.max_output_bytes()

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
          File.mkdir_p(workspace)

          Logger.debug("[ShellExecute] Dispatching command via Sandbox.Executor")

          case Executor.execute(trimmed, workspace: workspace, cwd: workspace) do
            {:ok, output, 0} -> {:ok, maybe_truncate(output)}
            {:ok, output, code} -> {:error, "Exit #{code}:\n#{maybe_truncate(output)}"}
            {:error, reason} -> {:error, reason}
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
    # Check cd outside ~/.osa/ first (skill-specific workspace restriction).
    if cd_outside_osa?(command) do
      {:error, "Blocked: cd outside ~/.osa/ is not allowed"}
    else
      ShellPolicy.validate(command)
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
