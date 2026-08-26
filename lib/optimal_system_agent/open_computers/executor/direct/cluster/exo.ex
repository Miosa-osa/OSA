defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Exo do
  @moduledoc """
  Exo adapter for OpenComputers Inference Clusters.

  Manages the exo process on this host. Exo (github.com/exo-explore/exo)
  distributes large language model inference across multiple Apple Silicon Macs.

  ## What this module does

    1. Install exo (pip install exo-ml or git clone + pip install -e .)
    2. Start `exo run <model>` with the correct peer configuration
    3. Emit `cluster_provision_progress` frames for each phase
    4. When exo's HTTP server is available on port 52415, emit `cluster_ready`
    5. Monitor the process — emit `cluster_error` on crash

  ## Exo CLI

  As of exo v0.0.x:
    exo run <model_id>          # leader and standalone
    exo run <model_id> --peer <ip:port>   # connect to existing leader

  The HTTP API is always on localhost:52415.

  ## Long provisioning times

  Downloading 671B models takes hours. Progress frames are emitted for each
  download phase so the UI can show a meaningful progress bar.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @exo_port 52_415
  @model_download_poll_ms 5_000
  @ready_check_max_attempts 360
  # 30 minutes max wait for download

  # Map of running exo OS processes: %{cluster_id => port()}
  # Using persistent_term for cross-process visibility in the same node
  @process_registry :cluster_exo_processes

  def provision(%{cluster_id: cluster_id, model: model, role: role, peers: peers, leader: leader}) do
    emit_progress(cluster_id, :installing_deps, 5, "Installing exo dependencies...")

    with :ok <- ensure_exo_installed(cluster_id),
         :ok <- start_exo_process(cluster_id, model, role, peers, leader) do
      :ok
    end
  end

  def stop(cluster_id) do
    case get_port(cluster_id) do
      nil ->
        :ok

      _port ->
        # Kill the exo process by cluster_id marker file
        kill_exo(cluster_id)
        delete_port(cluster_id)
        Logger.info("[Exo] stopped cluster=#{cluster_id}")
        :ok
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp ensure_exo_installed(cluster_id) do
    case System.find_executable("exo") do
      nil ->
        emit_progress(cluster_id, :installing_deps, 10, "exo not found, installing via pip...")

        case run_cmd("pip3", ["install", "exo-ml"], timeout: 300_000) do
          {:ok, _} ->
            emit_progress(cluster_id, :installing_deps, 25, "exo installed successfully")
            :ok

          {:error, reason} ->
            Logger.error("[Exo] pip install exo-ml failed: #{inspect(reason)}")
            # Try git install as fallback
            install_exo_from_source(cluster_id)
        end

      path ->
        Logger.info("[Exo] found exo at #{path}")
        :ok
    end
  end

  defp install_exo_from_source(cluster_id) do
    exo_dir = Path.expand("~/.osa/exo")
    File.mkdir_p!(exo_dir)

    emit_progress(cluster_id, :installing_deps, 15, "Cloning exo from GitHub...")

    with {:ok, _} <-
           run_cmd(
             "git",
             ["clone", "--depth=1", "https://github.com/exo-explore/exo.git", exo_dir],
             timeout: 120_000
           ),
         _ = emit_progress(cluster_id, :installing_deps, 20, "Installing exo from source..."),
         {:ok, _} <- run_cmd("pip3", ["install", "-e", "."], cwd: exo_dir, timeout: 300_000) do
      emit_progress(cluster_id, :installing_deps, 25, "exo installed from source")
      :ok
    else
      {:error, reason} ->
        {:error, {:install_failed, reason}}
    end
  end

  defp start_exo_process(cluster_id, model, role, peers, leader) do
    emit_progress(
      cluster_id,
      :downloading_model,
      30,
      "Starting exo — model download may take hours for large models..."
    )

    args = build_exo_args(model, role, peers, leader)
    Logger.info("[Exo] starting exo cluster=#{cluster_id} args=#{inspect(args)}")

    # Use CLUSTER_ID env var so we can find the process later
    env = [{"MIOSA_CLUSTER_ID", cluster_id}]
    pid_file = pid_file_path(cluster_id)

    # Start exo with nohup so it survives this Task ending
    shell_cmd = "exo #{Enum.join(args, " ")} & echo $! > #{pid_file}"

    case run_cmd("bash", ["-c", shell_cmd], env: env, timeout: 10_000) do
      {:ok, _} ->
        store_port(cluster_id, @exo_port)
        wait_for_exo_ready(cluster_id, model)

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  end

  defp build_exo_args(model, :leader, _peers, _leader) do
    # Leader starts normally — exo will listen on the default port
    [model, "--port", to_string(@exo_port)]
  end

  defp build_exo_args(model, :worker, _peers, leader) do
    # Worker connects to the leader's peer discovery port
    leader_addr = "#{leader.ip}:#{leader.port}"
    [model, "--peer", leader_addr]
  end

  defp wait_for_exo_ready(cluster_id, model, attempt \\ 0) do
    if attempt >= @ready_check_max_attempts do
      {:error, :ready_timeout}
    else
      pct = min(30 + div(attempt * 60, @ready_check_max_attempts), 90)

      if rem(attempt, 6) == 0 do
        emit_progress(
          cluster_id,
          :downloading_model,
          pct,
          "Waiting for exo to be ready (attempt #{attempt + 1}/#{@ready_check_max_attempts})..."
        )
      end

      case http_get("http://localhost:#{@exo_port}/v1/models") do
        {:ok, _body} ->
          emit_progress(cluster_id, :ready, 100, "Cluster ready — exo is serving inference")

          FrameRouter.send_frame(
            {:cluster_ready,
             %{
               cluster_id: cluster_id,
               endpoint_port: @exo_port,
               capabilities: %{
                 model: model,
                 backend: "exo",
                 context_length: 8192,
                 supports_tools: false
               }
             }}
          )

          :ok

        {:error, _} ->
          # Not ready yet — sleep and retry
          :timer.sleep(@model_download_poll_ms)
          wait_for_exo_ready(cluster_id, model, attempt + 1)
      end
    end
  end

  defp http_get(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      _ -> {:error, :not_ready}
    end
  end

  defp run_cmd(cmd, args, opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    cwd = Keyword.get(opts, :cwd, nil)
    env = Keyword.get(opts, :env, [])

    port_opts = [
      :stderr_to_stdout,
      :exit_status,
      {:args, args},
      {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
    ]

    port_opts = if cwd, do: [{:cd, String.to_charlist(cwd)} | port_opts], else: port_opts

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
    Path.expand("~/.osa/clusters/#{cluster_id}.pid")
  end

  defp kill_exo(cluster_id) do
    pid_file = pid_file_path(cluster_id)

    case File.read(pid_file) do
      {:ok, pid_str} ->
        pid = String.trim(pid_str)
        System.cmd("kill", ["-TERM", pid])
        File.rm(pid_file)

      {:error, _} ->
        # Try pkill by env var (best effort)
        System.cmd("pkill", ["-f", "MIOSA_CLUSTER_ID=#{cluster_id}"])
    end
  end

  # ── Port registry (ETS backed) ────────────────────────────────────────────────

  defp ensure_registry do
    case :ets.whereis(@process_registry) do
      :undefined -> :ets.new(@process_registry, [:named_table, :public, :set])
      _tid -> @process_registry
    end
  end

  defp store_port(cluster_id, port) do
    ensure_registry()
    :ets.insert(@process_registry, {cluster_id, port})
  end

  defp get_port(cluster_id) do
    ensure_registry()

    case :ets.lookup(@process_registry, cluster_id) do
      [{^cluster_id, port}] -> port
      [] -> nil
    end
  end

  defp delete_port(cluster_id) do
    ensure_registry()
    :ets.delete(@process_registry, cluster_id)
  end
end
