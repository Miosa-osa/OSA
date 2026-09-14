defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop do
  @moduledoc """
  Executor for `:stream_native_desktop` on the owner's physical desktop.

  Lifecycle (happy path):
    1. Select the host's native desktop adapter.
    2. Spawn that adapter and read its ephemeral RFB port.
    3. Open Mint WebSocket to `job.relay_url` via `Relay.open/1`.
    4. Reply `{:job_done, id, %{status: :streaming}}` to signal session start.
    5. Launch bridge (TCP ↔ WS) via `Bridge.start/3`; run until either side closes.
    6. On any exit: kill x11vnc, close WS, stop with `:normal`.

  This does not create an isolated desktop or provision a display session.
  """

  use GenServer, restart: :temporary
  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{
    Bridge,
    MacOS,
    Readiness,
    Relay,
    Wayland,
    Windows,
    X11vnc
  }

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(job, reply, opts \\ []) when is_map(job) and is_function(reply, 1) do
    GenServer.start_link(__MODULE__, {job, reply, opts})
  end

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init({job, reply, opts}) do
    Process.flag(:trap_exit, true)
    if lease = opts[:desktop_lease], do: Process.monitor(lease)
    send(self(), :run)
    {:ok, %{job: job, reply: reply, opts: opts, x11: nil, ws: nil, bridge: nil}}
  end

  @impl true
  def handle_info(:run, %{job: job, reply: reply, opts: opts} = state) do
    os_type = Keyword.get(opts, :os_type, :os.type())

    cond do
      os_type in [{:unix, :linux}, {:unix, :darwin}, {:win32, :nt}] ->
        case start_session(job, reply, os_type, opts) do
          {:ok, new_state} ->
            {:noreply, Map.merge(state, new_state)}

          {:error, reason, message} ->
            reply.({:job_fail, job.id, %{reason: reason, message: message}})
            {:stop, :normal, state}
        end

      true ->
        reply.(
          {:job_fail, job.id,
           %{reason: :unsupported_host_os, message: "stream_native_desktop: unsupported OS"}}
        )

        {:stop, :normal, state}
    end
  end

  # Bridge loop finished (either side closed).
  def handle_info({:relay_done, reason}, state) do
    Logger.info("[Desktop] relay finished: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{opts: opts} = state)
      when is_pid(pid) do
    cond do
      opts[:desktop_lease] == pid -> {:stop, :normal, state}
      match?(%Task{pid: ^pid}, state.bridge) -> {:stop, :normal, state}
      true -> {:noreply, state}
    end
  end

  # Desktop helper OS process exited (Port message).
  def handle_info({port, {:exit_status, status}}, %{x11: %{port: port}} = state) do
    Logger.warning("[Desktop] helper exited with status #{status}")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    if lease = get_in(state, [:opts, :desktop_lease]), do: send(lease, :revoke)
  end

  # ── Private ──────────────────────────────────────────────────────────

  @doc """
  Helper options from the request and a separately validated caller context.
  `input_authorized` must never be copied from the remote job payload.
  Existing two-argument executor callers remain read-only.
  """
  def launch_options(job, context) do
    options = %{
      allow_input:
        Map.get(job, :allow_input) === true and
          Keyword.get(context, :input_authorized) === true
    }

    if Map.has_key?(job, :display), do: Map.put(options, :display, job.display), else: options
  end

  defp spawn_desktop(job, os_type, context) do
    options = launch_options(job, context)

    case Readiness.backend(os_type) do
      :macos -> MacOS.spawn(options)
      :windows -> Windows.spawn(options)
      :wayland -> Wayland.spawn(options)
      :x11vnc -> X11vnc.spawn(Map.get(job, :display), options)
      _ -> {:error, :unsupported_host_os}
    end
  end

  defp kill_desktop(x11) do
    cond do
      match?(%MacOS{}, x11) -> MacOS.kill(x11)
      match?(%Windows{}, x11) -> Windows.kill(x11)
      match?(%Wayland{}, x11) -> Wayland.kill(x11)
      match?(%X11vnc{}, x11) -> X11vnc.kill(x11)
      true -> :ok
    end
  end

  defp start_session(job, reply, os_type, context) do
    relay_url = Map.get(job, :relay_url, "")

    case spawn_desktop(job, os_type, context) do
      {:ok, x11} ->
        try do
          lease = context[:desktop_lease]

          connection =
            if is_pid(lease) and not Process.alive?(lease),
              do: {:error, :desktop_grant_expired},
              else: Relay.open(relay_url)

          case connection do
            {:ok, ws} ->
              if is_pid(lease) and not Process.alive?(lease) do
                cleanup(%{x11: x11, ws: ws})
                {:error, :desktop_grant_expired, "desktop grant expired during relay startup"}
              else
                start_bridge(job, reply, x11, ws)
              end

            {:error, reason} ->
              kill_desktop(x11)
              {:error, :ws_connect_failed, inspect(reason)}
          end
        catch
          kind, reason ->
            kill_desktop(x11)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, {kind, msg}} when kind in [:missing_binary, :missing_display, :missing_helper] ->
        {:error, kind, msg}

      {:error, reason} ->
        {:error, :desktop_start_failed, inspect(reason)}
    end
  end

  defp start_bridge(job, reply, x11, ws) do
    state = %{job: job, reply: reply, x11: x11, ws: ws, bridge: nil}

    try do
      case Bridge.start(x11.vnc_port, ws, self()) do
        {:ok, task} ->
          :ok = reply.({:job_done, job.id, %{status: :streaming}})
          Process.monitor(task.pid)
          {:ok, %{state | bridge: task}}

        {:error, reason} ->
          cleanup(state)
          {:error, :bridge_start_failed, inspect(reason)}
      end
    catch
      kind, reason ->
        cleanup(state)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp cleanup(%{x11: x11, ws: {conn, ref, _ws}}) when not is_nil(x11) do
    kill_desktop(x11)
    send_ws_close(conn, ref)
  end

  defp cleanup(%{x11: x11}) when not is_nil(x11), do: kill_desktop(x11)
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
