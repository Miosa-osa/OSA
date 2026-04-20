defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.MlxDistributed do
  @moduledoc """
  MLX Distributed adapter for OpenComputers Inference Clusters.

  Uses Apple's mlx-lm with mpirun to distribute inference across multiple Macs.

  ## What this module does

    1. Install mlx-lm (pip install mlx-lm)
    2. Generate a hostfile with peer IPs
    3. Start `mpirun -np N python3 -m mlx_lm.distributed.serve --model <model>`
    4. Emit progress frames
    5. When the HTTP server is ready, emit cluster_ready

  ## MLX Distributed HTTP API

  mlx-lm's distributed serve exposes an OpenAI-compatible endpoint.
  Default port varies but we target 8080 for MLX (exo uses 52415).

  ## Prerequisites

  All hosts must be on the same network and reachable by IP.
  mpirun must be installed (brew install open-mpi).
  SSH must be passwordless between all hosts.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @mlx_port 8_080
  @ready_check_max_attempts 240
  @ready_check_interval_ms 5_000

  # ── Public API ────────────────────────────────────────────────────────────────

  def provision(%{cluster_id: cluster_id, model: model, role: role, peers: peers, leader: leader}) do
    emit_progress(cluster_id, :installing_deps, 5, "Installing mlx-lm...")

    with :ok <- ensure_mlx_installed(cluster_id),
         :ok <- ensure_mpirun_installed(cluster_id),
         :ok <- start_mlx_distributed(cluster_id, model, role, peers, leader) do
      :ok
    end
  end

  def stop(cluster_id) do
    pid_file = pid_file_path(cluster_id)

    case File.read(pid_file) do
      {:ok, pid_str} ->
        pid = String.trim(pid_str)
        System.cmd("kill", ["-TERM", pid])
        File.rm(pid_file)

      {:error, _} ->
        System.cmd("pkill", ["-f", "mlx_lm.distributed.serve"])
    end

    :ok
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp ensure_mlx_installed(cluster_id) do
    emit_progress(cluster_id, :installing_deps, 10, "Checking mlx-lm installation...")

    needs_install =
      case run_cmd("python3", ["-c", "import mlx_lm; print('ok')"]) do
        {:ok, output} when is_binary(output) -> not String.contains?(output, "ok")
        _ -> true
      end

    if not needs_install do
      emit_progress(cluster_id, :installing_deps, 15, "mlx-lm already installed")
      :ok
    else
      emit_progress(cluster_id, :installing_deps, 12, "Installing mlx-lm via pip...")

      case run_cmd("pip3", ["install", "mlx-lm"], timeout: 300_000) do
        {:ok, _} ->
          emit_progress(cluster_id, :installing_deps, 20, "mlx-lm installed")
          :ok

        {:error, reason} ->
          {:error, {:mlx_install_failed, reason}}
      end
    end
  end

  defp ensure_mpirun_installed(cluster_id) do
    case System.find_executable("mpirun") do
      nil ->
        emit_progress(cluster_id, :installing_deps, 22, "Installing Open MPI...")

        case run_cmd("brew", ["install", "open-mpi"], timeout: 300_000) do
          {:ok, _} ->
            emit_progress(cluster_id, :installing_deps, 25, "Open MPI installed")
            :ok

          {:error, reason} ->
            {:error, {:mpirun_install_failed, reason}}
        end

      _path ->
        :ok
    end
  end

  defp start_mlx_distributed(cluster_id, model, :leader, peers, _leader) do
    # Leader: run mpirun coordinating all peers
    emit_progress(cluster_id, :downloading_model, 30, "Generating hostfile...")

    hostfile = generate_hostfile(cluster_id, peers)

    n_hosts = length(peers)

    emit_progress(
      cluster_id,
      :starting,
      35,
      "Starting MLX distributed (#{n_hosts} hosts) — model download may take hours..."
    )

    pid_file = pid_file_path(cluster_id)

    cmd =
      "mpirun -np #{n_hosts} --hostfile #{hostfile} " <>
        "python3 -m mlx_lm.distributed.serve --model #{model} --port #{@mlx_port} & echo $! > #{pid_file}"

    case run_cmd("bash", ["-c", cmd], timeout: 30_000) do
      {:ok, _} ->
        wait_for_mlx_ready(cluster_id, model)

      {:error, reason} ->
        {:error, {:mlx_start_failed, reason}}
    end
  end

  defp start_mlx_distributed(cluster_id, model, :worker, _peers, leader) do
    # Workers: just confirm MPI will reach us — mpirun drives everything from leader
    emit_progress(
      cluster_id,
      :joining_mesh,
      40,
      "Worker ready — waiting for leader (#{leader.ip}) to coordinate via MPI..."
    )

    # Workers don't need to do anything explicit — mpirun on the leader starts processes on workers
    # via SSH. We emit ready after a brief wait to confirm we're reachable.
    :timer.sleep(5_000)
    emit_progress(cluster_id, :ready, 100, "Worker ready to receive MPI rank assignment")

    FrameRouter.send_frame(
      {:cluster_ready,
       %{
         cluster_id: cluster_id,
         endpoint_port: @mlx_port,
         capabilities: %{model: model, backend: "mlx-distributed"}
       }}
    )

    :ok
  end

  defp generate_hostfile(cluster_id, peers) do
    dir = Path.expand("~/.osa/clusters")
    File.mkdir_p!(dir)
    hostfile = Path.join(dir, "#{cluster_id}.hostfile")

    content =
      peers
      |> Enum.map(fn %{ip: ip} -> "#{ip} slots=1" end)
      |> Enum.join("\n")

    File.write!(hostfile, content)
    hostfile
  end

  defp wait_for_mlx_ready(cluster_id, model, attempt \\ 0) do
    if attempt >= @ready_check_max_attempts do
      {:error, :ready_timeout}
    else
      pct = min(40 + div(attempt * 55, @ready_check_max_attempts), 95)

      if rem(attempt, 6) == 0 do
        emit_progress(
          cluster_id,
          :downloading_model,
          pct,
          "Waiting for MLX server (attempt #{attempt + 1})..."
        )
      end

      case http_get("http://localhost:#{@mlx_port}/v1/models") do
        {:ok, _body} ->
          emit_progress(cluster_id, :ready, 100, "MLX distributed cluster ready")

          FrameRouter.send_frame(
            {:cluster_ready,
             %{
               cluster_id: cluster_id,
               endpoint_port: @mlx_port,
               capabilities: %{
                 model: model,
                 backend: "mlx-distributed",
                 context_length: 4096,
                 supports_tools: false
               }
             }}
          )

          :ok

        {:error, _} ->
          :timer.sleep(@ready_check_interval_ms)
          wait_for_mlx_ready(cluster_id, model, attempt + 1)
      end
    end
  end

  defp http_get(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      _ -> {:error, :not_ready}
    end
  end

  defp run_cmd(cmd, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    env = Keyword.get(opts, :env, [])

    port_opts = [
      :stderr_to_stdout,
      :exit_status,
      {:args, args},
      {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
    ]

    port = Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, port_opts)
    collect_port_output(port, "", timeout)
  end

  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> to_string(data), timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, {:exit_code, code, acc}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp emit_progress(cluster_id, phase, progress, message) do
    FrameRouter.send_frame(
      {:cluster_provision_progress,
       %{
         cluster_id: cluster_id,
         phase: phase,
         progress: progress,
         message: message
       }}
    )
  end

  defp pid_file_path(cluster_id) do
    dir = Path.expand("~/.osa/clusters")
    File.mkdir_p!(dir)
    Path.join(dir, "#{cluster_id}.pid")
  end
end
