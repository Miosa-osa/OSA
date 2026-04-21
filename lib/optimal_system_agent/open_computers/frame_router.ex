defmodule OptimalSystemAgent.OpenComputers.FrameRouter do
  @moduledoc """
  Routes inbound frames from the control plane to the appropriate executor,
  and routes outbound frames from executors to the control-plane WS connection.

  ## Inbound routing (control plane → OSA)

  Frames received by `HostClient` are dispatched here. The router inspects the
  frame tag and forwards to the appropriate executor module:

  | Frame tag           | Handler                                  |
  |---------------------|------------------------------------------|
  | `:desktop_*`        | `Desktop.Controller`                     |
  | `:exec_request`     | (reserved for exec agent — separate task)|
  | `:job`              | (reserved for VM dispatch — separate)    |
  | `:heartbeat`        | (no-op — sent by control plane, handled) |

  ## Outbound routing (OSA → control plane)

  Executor modules call `FrameRouter.send_frame/1`. The router forwards the
  frame to `HostClient` (the WS connection process) via `{:send_frame, frame}`.

  ## Process model

  The FrameRouter is a lightweight GenServer — it does not own any IO resources,
  just routes. It is started under the OpenComputers supervisor.

  ## Extensibility

  Adding support for a new executor:
    1. Add a `dispatch_inbound/1` clause matching the new frame tags
    2. The executor calls `FrameRouter.send_frame/1` for outbound frames
    3. Register the new executor GenServer under the OC supervisor
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller, as: DesktopController
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Pty, as: PtyExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Tunnel, as: TunnelExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Controller, as: ClusterController
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.GhaRunner, as: GhaRunnerExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Backup, as: BackupExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.WgMesh, as: WgMeshExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Container, as: ContainerExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Compose, as: ComposeExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.SshKeys, as: SshKeysExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Clipboard, as: ClipboardExecutor

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc """
  Route an inbound frame from the control plane to the appropriate executor.
  Called by `HostClient` on every received binary frame.
  """
  @spec dispatch(term()) :: :ok
  def dispatch(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  @doc """
  Send an outbound frame from an executor to the control plane.
  Called by executors (Desktop.Controller, etc.) to send frames upstream.
  """
  @spec send_frame(term()) :: :ok
  def send_frame(frame) do
    GenServer.cast(__MODULE__, {:outbound, frame})
  end

  @doc "Register the HostClient pid so outbound frames can be forwarded."
  @spec register_host_client(pid()) :: :ok
  def register_host_client(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register_host_client, pid})
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{host_client_pid: nil}}
  end

  @impl true
  def handle_call({:register_host_client, pid}, _from, state) do
    Process.monitor(pid)
    Logger.info("[FrameRouter] registered host_client pid=#{inspect(pid)}")
    {:reply, :ok, %{state | host_client_pid: pid}}
  end

  @impl true
  # ── Inbound dispatch ──

  def handle_cast({:inbound, {:desktop_start_request, _} = frame}, state) do
    dispatch_to_desktop(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:desktop_data, _} = frame}, state) do
    dispatch_to_desktop(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:desktop_stop, _} = frame}, state) do
    dispatch_to_desktop(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:pty_open_request, _} = frame}, state) do
    dispatch_to_pty(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:pty_input, _} = frame}, state) do
    dispatch_to_pty(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:pty_resize, _} = frame}, state) do
    dispatch_to_pty(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:pty_close, _} = frame}, state) do
    dispatch_to_pty(frame)
    {:noreply, state}
  end

  # Tunnel frames — route to TunnelExecutor
  def handle_cast({:inbound, {:tunnel_open_request, _} = frame}, state) do
    dispatch_to_tunnel(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:tunnel_request_body, _} = frame}, state) do
    dispatch_to_tunnel(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:tunnel_close, _} = frame}, state) do
    dispatch_to_tunnel(frame)
    {:noreply, state}
  end

  # Cluster frames — route to Cluster.Controller
  def handle_cast({:inbound, {:cluster_provision_request, _} = frame}, state) do
    dispatch_to_cluster(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:cluster_stop_request, _} = frame}, state) do
    dispatch_to_cluster(frame)
    {:noreply, state}
  end

  # GHA Runner frames — route to GhaRunner executor
  def handle_cast({:inbound, {:gha_runner_setup_request, _} = frame}, state) do
    dispatch_to_gha_runner(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:gha_runner_stop_request, _} = frame}, state) do
    dispatch_to_gha_runner(frame)
    {:noreply, state}
  end

  # osa_update_staged — outbound only (sent by Updater, upstream to control plane).
  # If the control plane echoes it back inbound, ignore.
  def handle_cast({:inbound, {:osa_update_staged, _} = frame}, state) do
    Logger.debug(
      "[FrameRouter] inbound osa_update_staged echo (ignored): #{inspect(elem(frame, 0))}"
    )

    {:noreply, state}
  end

  # Backup frames — route to BackupExecutor
  def handle_cast({:inbound, {:backup_snapshot_request, _} = frame}, state) do
    dispatch_to_backup(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:backup_restore_request, _} = frame}, state) do
    dispatch_to_backup(frame)
    {:noreply, state}
  end

  # WireGuard mesh frames — route to WgMeshExecutor
  def handle_cast({:inbound, {:wg_init_request, _} = frame}, state) do
    dispatch_to_wg_mesh(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:wg_configure, _} = frame}, state) do
    dispatch_to_wg_mesh(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:wg_teardown_request, _} = frame}, state) do
    dispatch_to_wg_mesh(frame)
    {:noreply, state}
  end

  # Container frames — route to ContainerExecutor
  def handle_cast({:inbound, {:container_run_request, _} = frame}, state) do
    dispatch_to_container(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:container_logs_subscribe, _} = frame}, state) do
    dispatch_to_container(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:container_logs_unsubscribe, _} = frame}, state) do
    dispatch_to_container(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:container_stop_request, _} = frame}, state) do
    dispatch_to_container(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:container_remove_request, _} = frame}, state) do
    dispatch_to_container(frame)
    {:noreply, state}
  end

  # Compose frames — route to ComposeExecutor
  def handle_cast({:inbound, {:compose_up_request, _} = frame}, state) do
    dispatch_to_compose(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:compose_down_request, _} = frame}, state) do
    dispatch_to_compose(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:compose_ps_request, _} = frame}, state) do
    dispatch_to_compose(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:compose_logs_subscribe, _} = frame}, state) do
    dispatch_to_compose(frame)
    {:noreply, state}
  end

  # SSH key frames — route to SshKeysExecutor
  def handle_cast({:inbound, {:ssh_key_add_request, _} = frame}, state) do
    dispatch_to_ssh_keys(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:ssh_key_remove_request, _} = frame}, state) do
    dispatch_to_ssh_keys(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:ssh_key_list_request, _} = frame}, state) do
    dispatch_to_ssh_keys(frame)
    {:noreply, state}
  end

  # Clipboard frames — route to ClipboardExecutor
  def handle_cast({:inbound, {:clipboard_copy_to_host, _} = frame}, state) do
    dispatch_to_clipboard(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, {:clipboard_request_from_host, _} = frame}, state) do
    dispatch_to_clipboard(frame)
    {:noreply, state}
  end

  def handle_cast({:inbound, frame}, state) do
    Logger.debug("[FrameRouter] unhandled inbound frame: #{inspect(elem(frame, 0))}")
    {:noreply, state}
  end

  # ── Outbound dispatch ──

  def handle_cast({:outbound, frame}, %{host_client_pid: nil} = state) do
    Logger.warning(
      "[FrameRouter] outbound frame dropped — no host_client registered: #{inspect(frame)}"
    )

    {:noreply, state}
  end

  def handle_cast({:outbound, frame}, %{host_client_pid: pid} = state) when is_pid(pid) do
    send(pid, {:send_frame, frame})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{host_client_pid: pid} = state) do
    Logger.warning("[FrameRouter] host_client died: #{inspect(reason)}")
    {:noreply, %{state | host_client_pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────────────────

  defp dispatch_to_desktop(frame) do
    case Process.whereis(DesktopController) do
      nil ->
        Logger.warning(
          "[FrameRouter] DesktopController not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        DesktopController.handle_frame(frame)
    end
  end

  defp dispatch_to_pty(frame) do
    case Process.whereis(PtyExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] PtyExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        PtyExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_tunnel(frame) do
    case Process.whereis(TunnelExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] TunnelExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        TunnelExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_cluster(frame) do
    case Process.whereis(ClusterController) do
      nil ->
        Logger.warning(
          "[FrameRouter] ClusterController not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        ClusterController.handle_frame(frame)
    end
  end

  defp dispatch_to_gha_runner(frame) do
    case Process.whereis(GhaRunnerExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] GhaRunnerExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        GhaRunnerExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_backup(frame) do
    case Process.whereis(BackupExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] BackupExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        BackupExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_wg_mesh(frame) do
    case Process.whereis(WgMeshExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] WgMeshExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        WgMeshExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_container(frame) do
    case Process.whereis(ContainerExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] ContainerExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        ContainerExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_compose(frame) do
    case Process.whereis(ComposeExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] ComposeExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        ComposeExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_ssh_keys(frame) do
    case Process.whereis(SshKeysExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] SshKeysExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        SshKeysExecutor.handle_frame(frame)
    end
  end

  defp dispatch_to_clipboard(frame) do
    case Process.whereis(ClipboardExecutor) do
      nil ->
        Logger.warning(
          "[FrameRouter] ClipboardExecutor not running, dropping #{inspect(elem(frame, 0))}"
        )

      _pid ->
        ClipboardExecutor.handle_frame(frame)
    end
  end
end
