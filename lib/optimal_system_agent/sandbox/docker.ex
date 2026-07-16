defmodule OptimalSystemAgent.Sandbox.Docker do
  @moduledoc """
  Docker sandbox backend — runs code in isolated containers.

  Security hardening:
  - `--cap-drop ALL` — drop all Linux capabilities
  - `--network none` — no network access
  - `--read-only` — read-only root filesystem
  - `--pids-limit 100` — prevent fork bombs
  - `--memory 256m` — memory limit
  - Workspace mounted at /workspace

  ## Configuration

  Enable in `~/.osa/sandbox.json`:
  ```json
  {
    "backend": "docker",
    "docker": {
      "image": "python:3.12-slim",
      "memory": "256m",
      "network": false,
      "timeout": 30
    }
  }
  ```

  Or in application config:
  ```elixir
  config :optimal_system_agent, :sandbox_backend, :docker
  config :optimal_system_agent, :sandbox_docker, %{
    image: "python:3.12-slim",
    memory: "256m"
  }
  ```
  """
  @behaviour OptimalSystemAgent.Sandbox.Behaviour

  require Logger

  @default_image "python:3.12-slim"
  @default_memory "256m"
  @default_timeout 30_000

  @impl true
  def available? do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def name, do: "docker"

  @impl true
  def execute(command, opts \\ []) do
    if not available?() do
      {:error, "Docker is not available. Install Docker or switch to :host backend."}
    else
      config = sandbox_config()
      image = Keyword.get(opts, :image, config[:image] || @default_image)
      timeout = Keyword.get(opts, :timeout, config[:timeout] || @default_timeout)
      memory = config[:memory] || @default_memory
      working_dir = Keyword.get(opts, :working_dir)
      network = if config[:network] == true, do: [], else: ["--network", "none"]

      # Build docker run command
      docker_args =
        [
          "run",
          "--rm",
          "--cap-drop",
          "ALL",
          "--read-only",
          "--pids-limit",
          "100",
          "--memory",
          memory
        ] ++ network

      # Mount working directory if provided
      docker_args =
        if working_dir do
          docker_args ++ ["-v", "#{working_dir}:/workspace", "-w", "/workspace"]
        else
          docker_args
        end

      # Mount tmpfs for /tmp (read-only root needs writable tmp)
      docker_args = docker_args ++ ["--tmpfs", "/tmp:rw,noexec,nosuid,size=64m"]

      docker_args = docker_args ++ [image, "sh", "-c", command]

      Logger.info("[Sandbox.Docker] Running in #{image}: #{String.slice(command, 0, 80)}")

      # `:timeout` is NOT a valid System.cmd/3 option (it raises ArgumentError,
      # which the rescue below would turn into a blanket failure — making the
      # Docker backend never run). Enforce the wall-clock timeout via Task.yield
      # + Task.shutdown, the same pattern host.ex / code_sandbox.ex use.
      try do
        task =
          Task.async(fn ->
            System.cmd("docker", docker_args, stderr_to_stdout: true)
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} -> {:ok, output}
          {:ok, {output, code}} -> {:error, "Container exit code #{code}: #{output}"}
          nil -> {:error, "Docker execution timed out after #{timeout}ms"}
        end
      rescue
        e -> {:error, "Docker execution failed: #{Exception.message(e)}"}
      end
    end
  end

  @impl true
  def run_file(path, opts \\ []) do
    ext = Path.extname(path)
    filename = Path.basename(path)

    # Select appropriate image based on file type
    {image, run_cmd} =
      case ext do
        ".py" -> {"python:3.12-slim", "python3 /workspace/#{filename}"}
        ".js" -> {"node:22-slim", "node /workspace/#{filename}"}
        ".ts" -> {"node:22-slim", "npx tsx /workspace/#{filename}"}
        ".rb" -> {"ruby:3.3-slim", "ruby /workspace/#{filename}"}
        ".go" -> {"golang:1.23-alpine", "go run /workspace/#{filename}"}
        _ -> {"alpine:latest", "sh /workspace/#{filename}"}
      end

    dir = Path.dirname(path)
    execute(run_cmd, [{:image, image}, {:working_dir, dir} | opts])
  end

  defp sandbox_config do
    Application.get_env(:optimal_system_agent, :sandbox_docker, %{})
  end
end
