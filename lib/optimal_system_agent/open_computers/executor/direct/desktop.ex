defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop do
  @moduledoc """
  Executor for `:stream_native_desktop` (Linux only — Phase 1).

  Lifecycle (happy path):
    1. Guard: Linux only; macOS/Windows → immediate `:job_fail`.
    2. Spawn x11vnc via `X11vnc.spawn/1`; parse ephemeral RFB port.
    3. Open Mint WebSocket to `job.relay_url` via `Relay.open/1`.
    4. Reply `{:job_done, id, %{status: :streaming}}` to signal session start.
    5. Launch bridge (TCP ↔ WS) via `Bridge.start/3`; run until either side closes.
    6. On any exit: kill x11vnc, close WS, stop with `:normal`.

  macOS / Windows will be wired up in Phase 2.
  """

  use GenServer, restart: :temporary
  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{Bridge, Relay, X11vnc}

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(job, reply) when is_map(job) and is_function(reply, 1) do
    GenServer.start_link(__MODULE__, {job, reply})
  end

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init({job, reply}) do
    send(self(), :run)
    {:ok, %{job: job, reply: reply, x11: nil, ws: nil, bridge: nil}}
  end

  @impl true
  def handle_info(:run, %{job: job, reply: reply} = state) do
    if not linux?() do
      reply.(
        {:job_fail, job.id,
         %{reason: :unsupported_host_os, message: "stream_native_desktop: Phase 2 (macOS/Windows)"}}
      )

      {:stop, :normal, state}
    else
      case start_session(job, reply) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, reason, message} ->
          reply.({:job_fail, job.id, %{reason: reason, message: message}})
          {:stop, :normal, state}
      end
    end
  end

  # Bridge loop finished (either side closed).
  def handle_info({:relay_done, reason}, state) do
    Logger.info("[Desktop] relay finished: #{inspect(reason)}")
    cleanup(state)
    {:stop, :normal, state}
  end

  # x11vnc OS process exited (Port message).
  def handle_info({port, {:exit_status, status}}, %{x11: %{port: port}} = state) do
    Logger.warning("[Desktop] x11vnc exited with status #{status}")
    cleanup(state)
    {:stop, :normal, state}
  end

  # Bridge Task exited.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{bridge: %Task{pid: pid}} = state) do
    Logger.info("[Desktop] bridge task down: #{inspect(reason)}")
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ──────────────────────────────────────────────────────────

  defp linux?, do: :os.type() == {:unix, :linux}

  defp start_session(job, reply) do
    relay_url = Map.get(job, :relay_url, "")
    display = Map.get(job, :display, ":0")

    with {:x11, {:ok, x11}} <- {:x11, X11vnc.spawn(display)},
         {:ws, {:ok, ws}} <- {:ws, Relay.open(relay_url)},
         :ok <- reply.({:job_done, job.id, %{status: :streaming}}),
         {:bridge, {:ok, task}} <- {:bridge, Bridge.start(x11.vnc_port, ws, self())} do
      Process.monitor(task.pid)
      {:ok, %{job: job, reply: reply, x11: x11, ws: ws, bridge: task}}
    else
      {:x11, {:error, {:missing_binary, msg}}} -> {:error, :missing_binary, msg}
      {:x11, {:error, {:missing_display, msg}}} -> {:error, :missing_display, msg}
      {:x11, {:error, reason}} -> {:error, :x11vnc_start_failed, inspect(reason)}
      {:ws, {:error, reason}} -> {:error, :ws_connect_failed, inspect(reason)}
      {:bridge, {:error, reason}} -> {:error, :bridge_start_failed, inspect(reason)}
    end
  end

  defp cleanup(%{x11: x11, ws: {conn, ref, _ws}}) when not is_nil(x11) do
    X11vnc.kill(x11)
    send_ws_close(conn, ref)
  end

  defp cleanup(%{x11: x11}) when not is_nil(x11), do: X11vnc.kill(x11)
  defp cleanup(_state), do: :ok

  defp send_ws_close(conn, ref) do
    try do
      Mint.HTTP.close(conn)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    _ = ref
    :ok
  end
end
