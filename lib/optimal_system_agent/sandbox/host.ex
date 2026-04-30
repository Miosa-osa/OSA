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

    args = ["-c", command]
    cmd_opts = [stderr_to_stdout: true, timeout: timeout]
    cmd_opts = if working_dir, do: [{:cd, working_dir} | cmd_opts], else: cmd_opts

    try do
      case System.cmd("sh", args, cmd_opts) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:error, "Exit code #{code}: #{output}"}
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
        _ -> "sh #{path}"
      end

    execute(command, opts)
  end
end
