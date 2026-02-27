defmodule OptimalSystemAgent.Sandbox.Docker do
  @moduledoc """
  Docker-based sandbox for skill execution.

  Creates ephemeral, single-use containers per command:

  - Read-only root filesystem (`--read-only`)
  - No network by default (`--network none`), configurable per call
  - Resource limits: CPU and memory via Docker flags
  - Mounted workspace directory as the only writable path
  - A small tmpfs at /tmp for programs that need it
  - All Linux capabilities dropped (`--cap-drop ALL`)
  - Non-root user inside container (UID 1000)
  - `--no-new-privileges` to block setuid escalation
  - `--rm` so containers are automatically deleted after exit
  - Forceful `docker kill` on timeout so no zombie containers remain

  ## Design notes

  Each `execute/2` call is independent — there is no shared container state
  between calls. The `Pool` module (higher layer) may wrap this to pre-warm
  containers for lower latency, but `Docker` itself is stateless.
  """

  require Logger

  @type exec_result ::
          {:ok, output :: String.t(), exit_code :: non_neg_integer()}
          | {:error, reason :: String.t()}

  @doc """
  Check whether the Docker daemon is reachable from this host.

  Runs `docker info` and treats any non-zero exit as "not available".
  Does not raise.
  """
  @spec available?() :: boolean()
  def available? do
    try do
      case System.cmd("docker", ["info"], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  @doc """
  Execute `command` (a shell string) inside a fresh Docker container.

  ## Options

  - `:workspace`      — host path to mount as `/workspace` (default `~/.osa/workspace`)
  - `:timeout`        — ms before the container is killed (default `30_000`)
  - `:network`        — `true` to allow outbound network; default `false` (network=none)
  - `:max_memory`     — Docker `--memory` value, e.g. `"256m"` (default `"256m"`)
  - `:max_cpu`        — Docker `--cpus` value, e.g. `"0.5"` (default `"0.5"`)
  - `:image`          — container image to run (default `"osa-sandbox:latest"`)
  - `:extra_env`      — `[{"KEY", "val"}, ...]` to pass with `-e` flags

  ## Return values

  - `{:ok, output, exit_code}` — command completed (exit_code may be non-zero)
  - `{:error, reason}`         — Docker unavailable, image missing, or timeout
  """
  @spec execute(String.t(), keyword()) :: exec_result()
  def execute(command, opts \\ []) do
    workspace =
      Keyword.get(opts, :workspace, Path.expand("~/.osa/workspace"))
      |> Path.expand()

    timeout = Keyword.get(opts, :timeout, 30_000)
    network = if Keyword.get(opts, :network, false), do: "bridge", else: "none"
    memory = Keyword.get(opts, :max_memory, "256m")
    cpus = Keyword.get(opts, :max_cpu, "0.5")
    image = Keyword.get(opts, :image, "osa-sandbox:latest")
    extra_env = Keyword.get(opts, :extra_env, [])

    # Unique container name so we can kill it on timeout without ambiguity
    container_name =
      "osa-sandbox-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    # Ensure the workspace directory exists on the host before mounting
    File.mkdir_p!(workspace)

    docker_args = build_docker_args(container_name, network, memory, cpus, workspace, extra_env, image, command)

    Logger.debug(
      "[Sandbox.Docker] Spawning container name=#{container_name} image=#{image} network=#{network} memory=#{memory} cpus=#{cpus}"
    )

    task =
      Task.async(fn ->
        try do
          System.cmd("docker", docker_args, stderr_to_stdout: true)
        rescue
          e ->
            {Exception.message(e), 1}
        end
      end)

    result = Task.yield(task, timeout) || Task.shutdown(task)

    case result do
      {:ok, {output, 0}} ->
        Logger.debug("[Sandbox.Docker] Container #{container_name} exited cleanly")
        {:ok, output, 0}

      {:ok, {output, code}} ->
        Logger.debug("[Sandbox.Docker] Container #{container_name} exited code=#{code}")
        {:ok, output, code}

      nil ->
        # Timeout — kill the container so it doesn't linger
        Logger.warning(
          "[Sandbox.Docker] Container #{container_name} timed out after #{timeout}ms — killing"
        )

        kill_container(container_name)
        {:error, "Container execution timed out after #{timeout}ms"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec build_docker_args(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          String.t(),
          String.t()
        ) :: [String.t()]
  defp build_docker_args(container_name, network, memory, cpus, workspace, extra_env, image, command) do
    base = [
      "run",
      # Auto-remove after exit — no lingering containers
      "--rm",
      "--name", container_name,
      # Network isolation
      "--network", network,
      # Resource limits
      "--memory", memory,
      "--cpus", cpus,
      # Security: read-only root FS
      "--read-only",
      # Small tmpfs so programs that need /tmp don't break
      "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m",
      # Security: block privilege escalation
      "--security-opt", "no-new-privileges:true",
      # Drop all Linux capabilities
      "--cap-drop", "ALL",
      # Mount workspace as read-write — the only writable persistent path
      "-v", "#{workspace}:/workspace:rw",
      # Start in /workspace
      "-w", "/workspace",
      # Non-root user (UID 1000 matches the 'osa' user baked into the image)
      "-u", "1000:1000",
    ]

    env_flags =
      Enum.flat_map(extra_env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    base ++ env_flags ++ [image, "sh", "-c", command]
  end

  @spec kill_container(String.t()) :: :ok
  defp kill_container(container_name) do
    try do
      System.cmd("docker", ["kill", container_name], stderr_to_stdout: true)
      Logger.debug("[Sandbox.Docker] Sent kill to container #{container_name}")
    rescue
      e ->
        Logger.warning(
          "[Sandbox.Docker] Could not kill container #{container_name}: #{Exception.message(e)}"
        )
    end

    :ok
  end
end
