defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller do
  @moduledoc """
  GenServer that manages per-session desktop VNC relay on the OSA host side.

  ## Responsibilities

  1. On `desktop_start_request`: detect OS, start the appropriate VNC server
     (x11vnc on Linux, the native helper on macOS/Windows), connect a local TCP
     socket to 127.0.0.1 on the port THAT SERVER REPORTED BINDING, and register
     the session in the per-session state map. If the backend does not report a
     port the session is refused — never fall back to a fixed port, which would
     relay whatever unrelated server happens to hold it.

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

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{
    MacOS,
    Readiness,
    Wayland,
    Windows,
    X11vnc
  }

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @vnc_host ~c"127.0.0.1"
  @connect_timeout_ms 5_000
  @max_queue_bytes 16 * 1024 * 1024

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.merge([name: __MODULE__], gen_opts))
  end

  @doc "Dispatch a `desktop_*` frame to the controller."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:frame, frame})
  end

  def handle_frame(frame, context),
    do: GenServer.cast(__MODULE__, {:authorized_frame, frame, context})

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) when is_list(opts) do
    Process.flag(:trap_exit, true)
    # sessions: %{session_id => %{vnc_socket, vnc_pid, queued_bytes}}
    # vnc_port_override: integer — ONLY honoured together with vnc_start_fn, i.e.
    #   in tests that point at a fake VNC server they started themselves. There
    #   is deliberately no way to force a fixed port in production: connecting to
    #   a port this controller did not watch the server bind is how OSA ended up
    #   piping whatever held :5900 (potentially the user's own desktop-sharing
    #   server) to the control plane.
    # vnc_start_fn: fn() -> {:ok, handle} | {:error, reason} — test hook
    # frame_router_pid: pid — used in tests to capture outbound frames without hijacking the global name
    state = %{
      sessions: %{},
      vnc_port_override: Keyword.get(opts, :vnc_port_override, nil),
      vnc_start_fn: Keyword.get(opts, :vnc_start_fn, nil),
      frame_router_pid: Keyword.get(opts, :frame_router_pid, nil)
    }

    {:ok, state}
  end

  # ── Frame dispatch ───────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:frame, {:desktop_start_request, %{session_id: session_id} = payload}}, state) do
    handle_cast(
      {:authorized_frame, {:desktop_start_request, Map.put(payload, :session_id, session_id)},
       []},
      state
    )
  end

  def handle_cast(
        {:authorized_frame, {:desktop_start_request, %{session_id: session_id} = payload},
         context},
        state
      ) do
    width = Map.get(payload, :width, 1920)
    height = Map.get(payload, :height, 1080)

    Logger.info(
      "[Desktop.Controller] desktop_start_request session=#{session_id} #{width}x#{height}"
    )

    state = close_session(state, session_id, :replaced)

    opts =
      OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.launch_options(payload, context)

    opts = Map.put(opts, :desktop_lease, context[:desktop_lease])

    case start_session(session_id, opts, state) do
      {:ok, session_state} ->
        lease = context[:desktop_lease]
        if lease, do: Process.monitor(lease)
        session_state = Map.put(session_state, :desktop_lease, lease)

        if is_pid(lease) and not Process.alive?(lease),
          do: send(self(), {:expired_desktop, session_id})

        new_sessions = Map.put(state.sessions, session_id, session_state)

        # The VNC server now requires a per-session password, and the RFB
        # client lives on the far side of the relay — it has to be told the
        # secret or the handshake fails.
        send_frame_via_router(
          {:desktop_ready,
           %{
             session_id: session_id,
             vnc_password: session_state.vnc_secret,
             capabilities: %{
               mouse: opts.allow_input,
               keyboard: opts.allow_input,
               clipboard: false
             }
           }},
          state
        )

        {:noreply, %{state | sessions: new_sessions}}

      {:error, reason} ->
        Logger.warning(
          "[Desktop.Controller] failed to start session=#{session_id}: #{inspect(reason)}"
        )

        send_frame_via_router(
          {:desktop_error,
           %{
             session_id: session_id,
             reason: reason
           }},
          state
        )

        {:noreply, state}
    end
  end

  def handle_cast(
        {:frame, {:desktop_data, %{session_id: session_id, direction: :upstream, data: data}}},
        state
      ) do
    case get_in(state.sessions, [session_id, :vnc_socket]) do
      nil ->
        Logger.debug(
          "[Desktop.Controller] upstream data for unknown session=#{session_id}, ignoring"
        )

        {:noreply, state}

      socket ->
        case :gen_tcp.send(socket, data) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            Logger.warning(
              "[Desktop.Controller] TCP send failed session=#{session_id}: #{inspect(reason)}"
            )

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
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    ids = for {id, session} <- state.sessions, session[:desktop_lease] == pid, do: id
    {:noreply, Enum.reduce(ids, state, &close_session(&2, &1, :grant_expired))}
  end

  def handle_info({:expired_desktop, session_id}, state),
    do: {:noreply, close_session(state, session_id, :grant_expired)}

  def handle_info({:tcp, socket, data}, state) do
    # Find which session this socket belongs to
    case find_session_by_socket(state.sessions, socket) do
      {session_id, session} ->
        queued = session.queued_bytes + byte_size(data)

        if queued > @max_queue_bytes do
          Logger.warning("[Desktop.Controller] session=#{session_id} queue cap exceeded, closing")

          send_frame_via_router(
            {:desktop_error, %{session_id: session_id, reason: :failed_to_start}},
            state
          )

          {:noreply, close_session(state, session_id, :queue_overflow)}
        else
          # Forward downstream bytes to the control plane
          send_frame_via_router(
            {:desktop_data,
             %{
               session_id: session_id,
               direction: :downstream,
               data: data
             }},
            state
          )

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
        send_frame_via_router({:desktop_stop, %{session_id: session_id}}, state)
        {:noreply, close_session(state, session_id, :tcp_closed)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    case find_session_by_socket(state.sessions, socket) do
      {session_id, _} ->
        Logger.warning("[Desktop.Controller] TCP error session=#{session_id}: #{inspect(reason)}")

        send_frame_via_router(
          {:desktop_error, %{session_id: session_id, reason: :failed_to_start}},
          state
        )

        {:noreply, close_session(state, session_id, :tcp_error)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, _status}}, state) when is_port(port) do
    sessions =
      Enum.filter(state.sessions, fn {_id, session} ->
        match?(%{port_ref: ^port}, session.vnc_pid)
      end)

    {:noreply,
     Enum.reduce(sessions, state, fn {id, _}, acc ->
       send_frame_via_router({:desktop_stop, %{session_id: id}}, acc)
       close_session(acc, id, :helper_exited)
     end)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.sessions, fn {id, _} -> close_session(state, id, :shutdown) end)
    :ok
  end

  # ── Private — session lifecycle ───────────────────────────────────────────────

  defp start_session(session_id, opts, controller_state) do
    with {:ok, vnc_handle} <- start_vnc(controller_state, opts) do
      try do
        result =
          with :ok <- maybe_sleep(controller_state),
               :ok <- live_grant(opts),
               {:ok, vnc_port} <- resolve_vnc_port(vnc_handle, controller_state),
               {:ok, socket} <- connect_vnc(vnc_port) do
            :inet.setopts(socket, active: :once)

            {:ok,
             %{
               vnc_socket: socket,
               vnc_pid: vnc_handle,
               vnc_port: vnc_port,
               vnc_secret: vnc_secret(vnc_handle),
               queued_bytes: 0
             }}
          end

        case result do
          {:ok, session} ->
            Logger.info("[Desktop.Controller] session=#{session_id} started")
            {:ok, session}

          error ->
            stop_vnc(vnc_handle)
            error
        end
      catch
        kind, reason ->
          stop_vnc(vnc_handle)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp start_vnc(%{vnc_start_fn: fun}, _opts) when is_function(fun, 0), do: fun.()
  defp start_vnc(%{vnc_start_fn: fun}, opts) when is_function(fun, 1), do: fun.(opts)

  defp start_vnc(_controller_state, opts) do
    case Readiness.backend() do
      :x11vnc ->
        X11vnc.start(opts)

      :wayland ->
        Wayland.start(opts)

      :macos ->
        MacOS.start(opts)

      :windows ->
        Windows.start(opts)

      _ ->
        {:error, :unsupported_platform}
    end
  end

  defp live_grant(%{desktop_lease: lease}) when is_pid(lease),
    do: if(Process.alive?(lease), do: :ok, else: {:error, :desktop_grant_expired})

  defp live_grant(_), do: :ok

  # Skip the startup sleep when a test hook is provided (fast tests)
  defp maybe_sleep(%{vnc_start_fn: fun}) when is_function(fun, 0), do: :ok
  defp maybe_sleep(_), do: :timer.sleep(500)

  @doc false
  # The RFB port must come from the server this controller actually started.
  # `vnc_port_override` is honoured only alongside the `vnc_start_fn` test
  # hook, where the test also owns the listening socket.
  def resolve_vnc_port(_handle, %{vnc_start_fn: fun, vnc_port_override: override})
      when is_function(fun, 0) and is_integer(override) and override > 0,
      do: {:ok, override}

  def resolve_vnc_port(%{vnc_port: port}, _state) when is_integer(port) and port > 0,
    do: {:ok, port}

  def resolve_vnc_port(handle, _state) do
    Logger.error(
      "[Desktop.Controller] VNC backend did not report the port it bound " <>
        "(handle=#{inspect(handle)}); refusing to connect to a port we did not start."
    )

    {:error, :vnc_port_unknown}
  end

  defp vnc_secret(%{secret: secret}) when is_binary(secret), do: secret
  defp vnc_secret(_), do: nil

  # Stop whichever VNC backend was used — the ref type tells us which adapter.
  # x11vnc returns an integer OS pid; macOS/Windows return a Port reference.
  defp stop_vnc(%{port_ref: port_ref}) when is_port(port_ref), do: stop_native(port_ref)

  defp stop_vnc(%{os_pid: os_pid}) when is_integer(os_pid), do: X11vnc.stop(os_pid)

  defp stop_vnc(pid_or_port) when is_integer(pid_or_port), do: X11vnc.stop(pid_or_port)

  defp stop_vnc(port_ref) when is_port(port_ref), do: stop_native(port_ref)

  defp stop_vnc(_), do: :ok

  defp stop_native(port_ref) do
    case os_family() do
      :macos -> MacOS.stop(port_ref)
      :windows -> Windows.stop(port_ref)
      :linux -> Wayland.stop(port_ref)
      _ -> :ok
    end
  end

  defp connect_vnc(port) when is_integer(port) do
    case :gen_tcp.connect(
           @vnc_host,
           port,
           [:binary, active: false, packet: :raw, nodelay: true],
           @connect_timeout_ms
         ) do
      {:ok, socket} ->
        {:ok, socket}

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

        # Stop VNC process if we started it — delegate to the platform adapter
        if session.vnc_pid, do: stop_vnc(session.vnc_pid)
        if lease = session[:desktop_lease], do: send(lease, :revoke)

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

  # Route outbound frames through either a test-injected pid or the global FrameRouter.
  # The frame_router_pid opt is set in tests to avoid hijacking the global named process.
  defp send_frame_via_router(frame, %{frame_router_pid: pid}) when is_pid(pid) do
    GenServer.cast(pid, {:outbound, frame})
  end

  defp send_frame_via_router(frame, _state) do
    FrameRouter.send_frame(frame)
  end
end
