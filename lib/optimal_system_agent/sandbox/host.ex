defmodule OptimalSystemAgent.Sandbox.Host do
  @moduledoc """
  Host backend — no sandbox, runs directly on the machine.

  This is the default. Code executes via System.cmd with the existing
  shell_execute security checks (security_check hook blocks dangerous commands).
  """
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def name, do: "host (no sandbox)"

  @impl true
  def execute(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    working_dir = Keyword.get(opts, :working_dir)

    cmd_opts = [stderr_to_stdout: true]
    cmd_opts = if working_dir, do: [{:cd, working_dir} | cmd_opts], else: cmd_opts

    try do
      task = Task.async(fn -> OptimalSystemAgent.OS.Shell.cmd(command, cmd_opts) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {output, code}} -> {:error, "Exit code #{code}: #{output}"}
        nil -> {:error, "Command timed out after #{div(timeout, 1000)}s"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @impl true
  def run_file(path, opts \\ []) do
    ext = Path.extname(path)

    command =
      case ext do
        ".py" -> "python3 #{path}"
        ".js" -> "node #{path}"
        ".ts" -> "npx tsx #{path}"
        ".rb" -> "ruby #{path}"
        ".sh" -> "bash #{path}"
        ".exs" -> "elixir #{path}"
        ".go" -> "go run #{path}"
        ".rs" -> "cargo script #{path}"
        ".ps1" -> "powershell -File #{path}"
        _ -> default_run_command(path)
      end

    execute(command, opts)
  end

  # On Windows there is no `sh`; execute the file directly through cmd. On
  # Unix keep the previous `sh <path>` behavior.
  defp default_run_command(path) do
    case :os.type() do
      {:win32, _} -> path
      _ -> "sh #{path}"
    end
  end
end
