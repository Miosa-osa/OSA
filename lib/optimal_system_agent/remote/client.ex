defmodule OptimalSystemAgent.Remote.Client do
  @moduledoc """
  OSA-side remote CLIENT: dials the MIOSA control-plane CLIENT endpoint,
  authenticates with the user's MIOSA account credential, and speaks the client
  half of the OpenComputers protocol (list hosts, create sessions, run
  exec/agent jobs, drive a PTY, list and kill sessions).

  ## Reuse, not duplication

  The transport is IDENTICAL to the host side, so this module reuses
  `OpenComputers.Session.Connector` (Mint connect + WS upgrade + the
  `miosa-opencomputers-v1` subprotocol), `Session.TlsOpts`, and
  `Session.FrameCodec` unchanged. Nothing in the host session/executor code is
  touched.

  ## Endpoint (configurable, mirrors the host side)

  Resolved by `control_url/0`, in order:

    1. `OSA_REMOTE_CONTROL_URL` environment variable
    2. `config :optimal_system_agent, :remote_control_url`
    3. default `wss://api.miosa.ai/api/v1/opencomputers/clients/ws`

  ## Server dependency (Phase 1)

  This endpoint and its session broker DO NOT EXIST on the MIOSA server yet
  (see `docs/OSA_REMOTE_DESIGN.md` section 6). Every network path therefore
  degrades gracefully: `open/1` returns `{:error, message}` with a clear,
  non-crashing explanation when the broker is unreachable, and each operation
  returns `{:error, message}` on timeout rather than raising.

  ## Concurrency model

  This is a GenServer, but the CLI usage is short-lived request/reply, so each
  operation blocks inside its `handle_call` doing a synchronous
  send-then-receive over the reused Mint socket. Long-lived shell streaming is
  handled by `stream_to/2`, which flips the socket into an async forwarding
  mode that delivers `{:remote_frame, frame}` messages to a destination pid (the
  `PtyBridge`).
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.Session.{Connector, FrameCodec}
  alias OptimalSystemAgent.Remote.Frames

  @default_url "wss://api.miosa.ai/api/v1/opencomputers/clients/ws"
  @connect_timeout_ms 10_000
  @default_call_timeout_ms 15_000

  # ── URL resolution ───────────────────────────────────────────────────────────

  @doc "The client control-plane URL (env override, then app config, then default)."
  @spec control_url() :: String.t()
  def control_url do
    System.get_env("OSA_REMOTE_CONTROL_URL") ||
      Application.get_env(:optimal_system_agent, :remote_control_url) ||
      @default_url
  end

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Open an authenticated client connection.

  Options:
    * `:token` (required) — the MIOSA account credential
    * `:url` — override `control_url/0`
    * `:connect_timeout` — ms (default #{@connect_timeout_ms})

  Returns `{:ok, pid}` on a successful handshake, or `{:error, message}` with a
  friendly explanation when the broker cannot be reached or auth is rejected.
  """
  @spec open(keyword()) :: {:ok, pid()} | {:error, String.t()}
  def open(opts) do
    token = Keyword.get(opts, :token)

    if is_nil(token) or token == "" do
      {:error, "no account credential supplied to Remote.Client.open/1"}
    else
      {:ok, pid} = GenServer.start_link(__MODULE__, opts)

      case GenServer.call(
             pid,
             :connect,
             Keyword.get(opts, :connect_timeout, @connect_timeout_ms) + 2_000
           ) do
        :ok ->
          {:ok, pid}

        {:error, message} ->
          _ = stop(pid)
          {:error, message}
      end
    end
  end

  @doc "List the hosts owned by the authenticated account."
  @spec list_hosts(pid(), timeout()) :: {:ok, [map()]} | {:error, String.t()}
  def list_hosts(pid, timeout \\ @default_call_timeout_ms) do
    GenServer.call(pid, {:list_hosts, timeout}, timeout + 2_000)
  end

  @doc "Ask the broker to allocate a session against `host` for `kind`."
  @spec create_session(pid(), String.t(), atom(), map(), timeout()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create_session(pid, host, kind, params \\ %{}, timeout \\ @default_call_timeout_ms) do
    GenServer.call(pid, {:create_session, host, kind, params, timeout}, timeout + 2_000)
  end

  @doc """
  Send a `{:job, ...}` frame (exec / agent) and await its terminal reply.
  Returns `{:ok, text}` on `:job_done`, `{:error, text}` on `:job_fail`/timeout.
  """
  @spec run_job(pid(), {:job, map()}, timeout()) :: {:ok, String.t()} | {:error, String.t()}
  def run_job(pid, {:job, _} = frame, timeout \\ @default_call_timeout_ms) do
    GenServer.call(pid, {:run_job, frame, timeout}, timeout + 2_000)
  end

  @doc "List live sessions on `host`."
  @spec list_sessions(pid(), String.t(), timeout()) :: {:ok, [map()]} | {:error, String.t()}
  def list_sessions(pid, host, timeout \\ @default_call_timeout_ms) do
    GenServer.call(pid, {:list_sessions, host, timeout}, timeout + 2_000)
  end

  @doc "Kill a session by id (host optional; the broker can resolve it)."
  @spec kill_session(pid(), String.t() | nil, String.t(), timeout()) ::
          :ok | {:error, String.t()}
  def kill_session(pid, host, session_id, timeout \\ @default_call_timeout_ms) do
    GenServer.call(pid, {:kill_session, host, session_id, timeout}, timeout + 2_000)
  end

  @doc "Fire-and-forget send of any frame (used by the PTY bridge)."
  @spec send_frame(pid(), term()) :: :ok
  def send_frame(pid, frame), do: GenServer.cast(pid, {:send_frame, frame})

  @doc """
  Flip into streaming mode: inbound frames are forwarded to `dest` as
  `{:remote_frame, frame}` messages. Used for interactive shell sessions.
  """
  @spec stream_to(pid(), pid()) :: :ok
  def stream_to(pid, dest), do: GenServer.call(pid, {:stream_to, dest})

  @doc "Close the connection and stop the client."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      conn: nil,
      ref: nil,
      websocket: nil,
      url: Keyword.get(opts, :url) || control_url(),
      token: Keyword.fetch!(opts, :token),
      connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout_ms),
      # decoded-but-unconsumed inbound frames
      pending: [],
      # when set, inbound frames are forwarded here instead of buffered
      stream_dest: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case do_connect(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call({:list_hosts, timeout}, _from, state) do
    with {:ok, state} <- send_frame_now(Frames.hosts_list_request(), state),
         {:ok, frame, state} <- await(state, &match?({:hosts_list, _}, &1), timeout) do
      case Frames.parse_hosts_list(frame) do
        {:ok, hosts} -> {:reply, {:ok, hosts}, state}
        :error -> {:reply, {:error, "malformed hosts_list reply"}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:create_session, host, kind, params, timeout}, _from, state) do
    ref = gen_ref()

    with {:ok, state} <-
           send_frame_now(Frames.session_create_request(ref, host, kind, params), state),
         {:ok, frame, state} <-
           await(state, &session_created_for?(&1, ref), timeout) do
      case Frames.parse_session_created(frame) do
        {:ok, %{session_id: sid}} -> {:reply, {:ok, sid}, state}
        :error -> {:reply, {:error, "malformed session_created reply"}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:run_job, {:job, job} = frame, timeout}, _from, state) do
    id = job[:id]

    with {:ok, state} <- send_frame_now(frame, state),
         {:ok, reply, state} <- await(state, &terminal_job_reply?(&1, id), timeout) do
      case Frames.summarize_job_reply(reply) do
        {:done, text} -> {:reply, {:ok, text}, state}
        {:fail, text} -> {:reply, {:error, text}, state}
        :ignore -> {:reply, {:error, "unexpected job reply"}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:list_sessions, host, timeout}, _from, state) do
    with {:ok, state} <- send_frame_now(Frames.sessions_list_request(host), state),
         {:ok, frame, state} <- await(state, &match?({:sessions_list, _}, &1), timeout) do
      case Frames.parse_sessions_list(frame) do
        {:ok, sessions} -> {:reply, {:ok, sessions}, state}
        :error -> {:reply, {:error, "malformed sessions_list reply"}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:kill_session, host, session_id, timeout}, _from, state) do
    with {:ok, state} <- send_frame_now(Frames.session_kill_request(host, session_id), state),
         {:ok, _frame, state} <- await(state, &match?({:session_killed, _}, &1), timeout) do
      {:reply, :ok, state}
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:stream_to, dest}, _from, state) do
    # Flush any already-buffered frames to the destination, then forward live.
    Enum.each(state.pending, fn frame -> send(dest, {:remote_frame, frame}) end)
    {:reply, :ok, %{state | stream_dest: dest, pending: []}}
  end

  @impl true
  def handle_cast({:send_frame, frame}, state) do
    case send_frame_now(frame, state) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, msg) do
      {:ok, conn, responses} ->
        {frames, ws} = decode_responses(responses, state.websocket)
        {:noreply, absorb_frames(frames, %{state | conn: conn, websocket: ws})}

      {:error, conn, _reason, _responses} ->
        {:noreply, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    _ = Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Connect + hello ──────────────────────────────────────────────────────────

  defp do_connect(state) do
    result =
      try do
        Connector.connect(state.url)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, {conn, ref, websocket}} ->
        state = %{state | conn: conn, ref: ref, websocket: websocket}
        handshake(state)

      {:error, _reason} ->
        {:error, unreachable_message(state.url), state}
    end
  end

  defp handshake(state) do
    with {:ok, state} <- send_frame_now(Frames.client_hello(state.token), state),
         {:ok, frame, state} <-
           await(state, &hello_reply?/1, state.connect_timeout) do
      case frame do
        {:client_hello_ok, _info} ->
          {:ok, state}

        {:client_error, info} ->
          {:error, "MIOSA rejected the account credential: #{auth_error(info)}", state}
      end
    else
      {:error, :timeout, state} ->
        {:error,
         "connected to #{state.url} but the broker did not complete the handshake " <>
           "(is the client endpoint implemented on the server?)", state}

      {:error, reason, state} ->
        {:error, transport_error(reason, state), state}
    end
  end

  # ── Synchronous send / receive over the reused Mint socket ───────────────────

  defp send_frame_now(_frame, %{conn: nil} = state), do: {:error, :not_connected, state}

  defp send_frame_now(frame, state) do
    bin = FrameCodec.encode(frame)

    case Mint.WebSocket.encode(state.websocket, {:binary, bin}) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn, websocket: websocket}}
          {:error, conn, reason} -> {:error, reason, %{state | conn: conn}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  # Block until a frame satisfies `pred` or the deadline elapses. Unmatched
  # frames stay buffered in `pending` (a later request may consume them).
  defp await(state, pred, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(state, pred, deadline, [])
  end

  defp await_loop(state, pred, deadline, seen) do
    case next_frame(state, deadline) do
      {:ok, frame, state} ->
        if pred.(frame) do
          {:ok, frame, %{state | pending: state.pending ++ Enum.reverse(seen)}}
        else
          await_loop(state, pred, deadline, [frame | seen])
        end

      {:timeout, state} ->
        {:error, :timeout, %{state | pending: state.pending ++ Enum.reverse(seen)}}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp next_frame(%{pending: [frame | rest]} = state, _deadline) do
    {:ok, frame, %{state | pending: rest}}
  end

  defp next_frame(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, state}
    else
      receive do
        msg ->
          case Mint.WebSocket.stream(state.conn, msg) do
            {:ok, conn, responses} ->
              {frames, ws} = decode_responses(responses, state.websocket)
              state = %{state | conn: conn, websocket: ws, pending: state.pending ++ frames}

              case state.pending do
                [frame | rest] -> {:ok, frame, %{state | pending: rest}}
                [] -> next_frame(state, deadline)
              end

            {:error, conn, reason, _responses} ->
              {:error, reason, %{state | conn: conn}}

            :unknown ->
              next_frame(state, deadline)
          end
      after
        remaining -> {:timeout, state}
      end
    end
  end

  # Decode a batch of Mint responses into a list of erlang-term frames.
  defp decode_responses(responses, websocket) do
    Enum.reduce(responses, {[], websocket}, fn
      {:data, _ref, data}, {acc, ws} ->
        case Mint.WebSocket.decode(ws, data) do
          {:ok, ws, ws_frames} ->
            terms =
              Enum.flat_map(ws_frames, fn
                {:binary, bin} ->
                  case FrameCodec.decode(bin) do
                    {:ok, term} -> [term]
                    :error -> []
                  end

                {:close, code, _reason} ->
                  [{:__closed__, code}]

                _other ->
                  []
              end)

            {acc ++ terms, ws}

          {:error, ws, _reason} ->
            {acc, ws}
        end

      _other, {acc, ws} ->
        {acc, ws}
    end)
  end

  # In streaming mode, forward frames to the destination; otherwise buffer.
  defp absorb_frames(frames, %{stream_dest: dest} = state) when is_pid(dest) do
    Enum.each(frames, fn frame -> send(dest, {:remote_frame, frame}) end)
    state
  end

  defp absorb_frames(frames, state), do: %{state | pending: state.pending ++ frames}

  # ── Predicates ───────────────────────────────────────────────────────────────

  defp hello_reply?({:client_hello_ok, _}), do: true
  defp hello_reply?({:client_error, _}), do: true
  defp hello_reply?(_), do: false

  defp session_created_for?({:session_created, %{ref: r}}, ref), do: r == ref
  defp session_created_for?(_, _), do: false

  defp terminal_job_reply?({:job_done, id, _}, id), do: true
  defp terminal_job_reply?({:job_fail, id, _}, id), do: true
  defp terminal_job_reply?(_, _), do: false

  # ── Messages ─────────────────────────────────────────────────────────────────

  defp unreachable_message(url) do
    "could not reach the OSA remote broker at #{url} " <>
      "(is your MIOSA account linked / is the server reachable?)"
  end

  defp transport_error(:timeout, state) do
    "the OSA remote broker at #{state.url} did not respond in time " <>
      "(the client endpoint may not be implemented on the server yet)"
  end

  defp transport_error(:not_connected, state) do
    "not connected to the OSA remote broker at #{state.url}"
  end

  defp transport_error({:__closed__, code}, state) do
    "the OSA remote broker at #{state.url} closed the connection (code #{code})"
  end

  defp transport_error(reason, state) do
    "transport error talking to the OSA remote broker at #{state.url}: #{inspect(reason)}"
  end

  defp auth_error(%{message: msg}), do: to_string(msg)
  defp auth_error(info), do: inspect(info)

  defp gen_ref, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
