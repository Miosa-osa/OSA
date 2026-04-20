defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller do
  @moduledoc """
  GenServer that manages per-session desktop VNC relay on the OSA host side.

  ## Responsibilities

  1. On `desktop_start_request`: detect OS, start the appropriate VNC server
     (x11vnc on Linux, stub on macOS/Windows), connect a local TCP socket to
     127.0.0.1:5900, and register the session in the per-session state map.

  2. VNC → Control plane: reads raw RFB bytes from the local TCP socket using
     `{:active, :once}` for backpressure, wraps them in a
     `{:desktop_data, %{session_id, direction: :downstream, data}}` frame, and
     sends them via the FrameRouter.

  3. Control plane → VNC: receives `{:desktop_data, %{direction: :upstream, data}}`
     messages forwarded by FrameRouter, and writes the bytes directly to the
     TCP socket via `:gen_tcp.send/2`.

  4. On `desktop_stop` (either direction): closes the TCP socket, stops the VNC
     process if this controller started it, and removes the session from state.

  ## Backpressure

  Uses `{:active, :once}` on the TCP socket — each received TCP message triggers
  exactly one `:inet.setopts(socket, active: :once)` after forwarding, preventing
  unbounded buffer growth when the control plane is slow.

  ## Session isolation

  Each session is keyed by `session_id` (UUID). Multiple concurrent desktop
  sessions per host are supported. The controller is a singleton GenServer;
  session state lives in `state.sessions`.

  ## In-memory queue cap

  Each session may buffer at most `@max_queue_bytes` of downstream data. When
  the cap is exceeded the session is forcibly closed with `:failed_to_start` error
  to prevent OOM. (Practical: noVNC browsers process frames fast; this is a safety
  net only.)
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{MacOS, Windows, X11vnc}
  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @vnc_host ~c"127.0.0.1"
  @vnc_port 5900
  @connect_timeout_ms 5_000
  @max_queue_bytes 16 * 1024 * 1024

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Dispatch a `desktop_*` frame to the controller."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:frame, frame})
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # sessions: %{session_id => %{vnc_socket, vnc_pid, queued_bytes}}
    {:ok, %{sessions: %{}}}
  end

  # ── Frame dispatch ───────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:frame, {:desktop_start_request, %{session_id: session_id} = payload}}, state) do
    width = Map.get(payload, :width, 1920)
    height = Map.get(payload, :height, 1080)

    Logger.info("[Desktop.Controller] desktop_start_request session=#{session_id} #{width}x#{height}")

    case start_session(session_id, %{width: width, height: height}) do
      {:ok, session_state} ->
        new_sessions = Map.put(state.sessions, session_id, session_state)

        FrameRouter.send_frame({:desktop_ready, %{
          session_id: session_id,
          capabilities: %{mouse: true, keyboard: true, clipboard: false}
        }})

        {:noreply, %{state | sessions: new_sessions}}

      {:error, reason} ->
        Logger.warning("[Desktop.Controller] failed to start session=#{session_id}: #{reason}")

        FrameRouter.send_frame({:desktop_error, %{
          session_id: session_id,
          reason: reason
        }})

        {:noreply, state}
    end
  end

  def handle_cast(
        {:frame, {:desktop_data, %{session_id: session_id, direction: :upstream, data: data}}},
        state
      ) do
    case get_in(state.sessions, [session_id, :vnc_socket]) do
      nil ->
        Logger.debug("[Desktop.Controller] upstream data for unknown session=#{session_id}, ignoring")
        {:noreply, state}

      socket ->
        case :gen_tcp.send(socket, data) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("[Desktop.Controller] TCP send failed session=#{session_id}: #{reason}")
            {:noreply, close_session(state, session_id, :tcp_error)}
        end
    end
  end

  def handle_cast({:frame, {:desktop_stop, %{session_id: session_id}}}, state) do
    Logger.info("[Desktop.Controller] desktop_stop session=#{session_id}")
    {:noreply, close_session(state, session_id, :requested)}
  end

  def handle_cast({:frame, _other}, state), do: {:noreply, state}

  # ── TCP messages from VNC socket ─────────────────────────────────────────────

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    # Find which session this socket belongs to
    case find_session_by_socket(state.sessions, socket) do
      {session_id, session} ->
        queued = session.queued_bytes + byte_size(data)

        if queued > @max_queue_bytes do
          Logger.warning("[Desktop.Controller] session=#{session_id} queue cap exceeded, closing")
          FrameRouter.send_frame({:desktop_error, %{session_id: session_id, reason: :failed_to_start}})
          {:noreply, close_session(state, session_id, :queue_overflow)}
        else
          # Forward downstream bytes to the control plane
          FrameRouter.send_frame({:desktop_data, %{
            session_id: session_id,
            direction: :downstream,
            data: data
          }})

          # Re-arm active once for backpressure
          :inet.setopts(socket, active: :once)

          new_session = %{session | queued_bytes: queued}
          {:noreply, put_in(state.sessions[session_id], new_session)}
        end

      nil ->
        # Unknown socket — likely a closed session, ignore
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, socket}, state) do
    case find_session_by_socket(state.sessions, socket) do
      {session_id, _} ->
        Logger.info("[Desktop.Controller] TCP closed session=#{session_id}")
        FrameRouter.send_frame({:desktop_stop, %{session_id: session_id}})
        {:noreply, close_session(state, session_id, :tcp_closed)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    case find_session_by_socket(state.sessions, socket) do
      {session_id, _} ->
        Logger.warning("[Desktop.Controller] TCP error session=#{session_id}: #{reason}")
        FrameRouter.send_frame({:desktop_error, %{session_id: session_id, reason: :failed_to_start}})
        {:noreply, close_session(state, session_id, :tcp_error)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private — session lifecycle ───────────────────────────────────────────────

  defp start_session(session_id, _opts) do
    with {:ok, vnc_pid} <- start_vnc(),
         # Give x11vnc a moment to bind its port
         :ok <- :timer.sleep(500) |> elem(0) |> then(fn _ -> :ok end),
         {:ok, socket} <- connect_vnc() do
      session = %{
        vnc_socket: socket,
        vnc_pid: vnc_pid,
        queued_bytes: 0
      }

      # Arm socket for async reads
      :inet.setopts(socket, active: :once)

      Logger.info("[Desktop.Controller] session=#{session_id} started")
      {:ok, session}
    end
  end

  defp start_vnc do
    case os_family() do
      :linux -> X11vnc.start()
      :macos -> MacOS.start()
      :windows -> Windows.start()
      _ -> {:error, :unsupported_platform}
    end
  end

  defp connect_vnc do
    case :gen_tcp.connect(@vnc_host, @vnc_port, [:binary, active: false, packet: :raw, nodelay: true], @connect_timeout_ms) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} ->
        Logger.error("[Desktop.Controller] TCP connect to VNC failed: #{reason}")
        {:error, :failed_to_start}
    end
  end

  defp close_session(state, session_id, reason) do
    case Map.get(state.sessions, session_id) do
      nil ->
        state

      session ->
        Logger.debug("[Desktop.Controller] closing session=#{session_id} reason=#{reason}")

        # Close TCP socket
        if session.vnc_socket, do: :gen_tcp.close(session.vnc_socket)

        # Stop VNC process if we started it
        if session.vnc_pid, do: X11vnc.stop(session.vnc_pid)

        %{state | sessions: Map.delete(state.sessions, session_id)}
    end
  end

  defp find_session_by_socket(sessions, socket) do
    Enum.find_value(sessions, fn {id, session} ->
      if session.vnc_socket == socket, do: {id, session}
    end)
  end

  defp os_family do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :macos
      {:win32, _} -> :windows
      _ -> :unknown
    end
  end
end
