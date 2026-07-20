defmodule OptimalSystemAgent.Remote.Client do
  @moduledoc """
  OSA-side remote CLIENT for the MIOSA miosa-compute #484 protocol.

  Dials the OpenComputers client endpoint
  (`wss://api.miosa.ai/api/v1/opencomputers/clients/ws`), negotiates the
  `miosa-opencomputers-client-v1` subprotocol, authenticates with the account's
  MIOSA platform key inside a `{:remote_hello, ...}` body, and then speaks the
  client half of the protocol: list hosts, open exec/agent sessions, stream the
  session's inner host frames back, and close sessions.

  ## Reuse

  The transport is the same `OpenComputers.Session.Connector` (Mint connect + WS
  upgrade) and `Session.FrameCodec` the host side uses; the client only passes a
  different `:subprotocol`. Every #484 message is wrapped in the
  `{:oc_remote, %{v: 1, request_id, body}}` envelope by `Remote.Frames`.

  ## Endpoint (configurable)

  Resolved by `control_url/0`: `OSA_REMOTE_CONTROL_URL`, then
  `config :optimal_system_agent, :remote_control_url`, then the default above.

  ## Graceful degradation

  When the endpoint is absent or auth is rejected, every path returns
  `{:error, message}` with a friendly, non-crashing explanation (including the
  `opencomputers:write` scope hint on a forbidden key), never a stack trace.

  ## Concurrency model

  A short-lived GenServer: each CLI operation blocks inside `handle_call` doing a
  synchronous send-then-receive over the reused Mint socket. Server `{:ping, seq}`
  frames are auto-answered with `{:pong, seq}` from inside the receive loop so the
  connection stays alive during long agent runs.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.Session.{Connector, FrameCodec}
  alias OptimalSystemAgent.Remote.Frames

  @subprotocol "miosa-opencomputers-client-v1"
  @default_url "wss://api.miosa.ai/api/v1/opencomputers/clients/ws"
  @connect_timeout_ms 10_000
  @default_call_timeout_ms 15_000

  # ── URL / identity resolution ────────────────────────────────────────────────

  @doc "The client control-plane URL (env override, then app config, then default)."
  @spec control_url() :: String.t()
  def control_url do
    System.get_env("OSA_REMOTE_CONTROL_URL") ||
      Application.get_env(:optimal_system_agent, :remote_control_url) ||
      @default_url
  end

  @doc """
  A stable per-install client identifier sent in `remote_hello`.

  Resolution: `OSA_REMOTE_CLIENT_ID` env, then a cached value in
  `<config_dir>/remote_client_id` (generated once on first use). Falls back to a
  freshly generated id if the file cannot be written.
  """
  @spec client_instance_id() :: String.t()
  def client_instance_id do
    case System.get_env("OSA_REMOTE_CLIENT_ID") do
      id when is_binary(id) and id != "" -> id
      _ -> cached_client_instance_id()
    end
  end

  defp cached_client_instance_id do
    path = Path.join(config_dir(), "remote_client_id")

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> generate_and_cache_id(path)
          id -> id
        end

      _ ->
        generate_and_cache_id(path)
    end
  end

  defp generate_and_cache_id(path) do
    id = "osa-" <> Frames.request_id()
    _ = File.mkdir_p(Path.dirname(path))
    _ = File.write(path, id)
    id
  end

  defp config_dir do
    Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()
  end

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Open an authenticated client connection.

  Options: `:token` (required, the MIOSA account key), `:url`, `:connect_timeout`,
  `:client_instance_id`. Returns `{:ok, pid}` after `remote_hello_ok`, or
  `{:error, message}` when the endpoint is unreachable or auth is rejected.
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

  @doc """
  Open a session on `host_id` for `kind` (`:exec` or `:agent`) with `params`
  (build these with `Frames.exec_params/2` or `Frames.agent_params/2`).
  Returns `{:ok, session_id}` or `{:error, message}`.
  """
  @spec open_session(pid(), String.t(), :exec | :agent, map(), timeout()) ::
          {:ok, String.t()} | {:error, String.t()}
  def open_session(pid, host_id, kind, params \\ %{}, timeout \\ @default_call_timeout_ms) do
    GenServer.call(pid, {:open_session, host_id, kind, params, timeout}, timeout + 2_000)
  end

  @doc """
  Await the terminal inner host frame for `session_id`, rendering any streamed
  `exec_chunk` output via `on_output` (an arity-1 function) as it arrives.
  Returns `{:ok, text}` on success, `{:error, text}` on failure/timeout/close.
  """
  @spec await_result(pid(), String.t(), timeout(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, String.t()}
  def await_result(
        pid,
        session_id,
        timeout \\ @default_call_timeout_ms,
        on_output \\ fn _ -> :ok end
      ) do
    GenServer.call(pid, {:await_result, session_id, timeout, on_output}, timeout + 2_000)
  end

  @doc "Close a session by id. Returns `:ok` or `{:error, message}`."
  @spec close_session(pid(), String.t(), timeout()) :: :ok | {:error, String.t()}
  def close_session(pid, session_id, timeout \\ @default_call_timeout_ms) do
    GenServer.call(pid, {:close_session, session_id, timeout}, timeout + 2_000)
  end

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
      client_instance_id: Keyword.get(opts, :client_instance_id) || client_instance_id(),
      connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout_ms),
      # decoded-but-unconsumed inbound bodies
      pending: []
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
    with {:ok, state} <- send_body_now(Frames.remote_hosts_list(), state),
         {:ok, body, state} <- await(state, &match?({:remote_hosts, _}, &1), timeout) do
      case Frames.parse_hosts(body) do
        {:ok, hosts} -> {:reply, {:ok, hosts}, state}
        :error -> {:reply, {:error, "malformed remote_hosts reply"}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:open_session, host_id, kind, params, timeout}, _from, state) do
    ref = gen_ref()

    with {:ok, state} <-
           send_body_now(Frames.remote_session_open(ref, host_id, kind, params), state),
         {:ok, body, state} <- await(state, &session_open_reply?(&1, ref), timeout) do
      case body do
        {:remote_session_opened, %{session_id: sid}} ->
          {:reply, {:ok, sid}, state}

        {:remote_error, info} ->
          {:reply, {:error, remote_error_message(info)}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:await_result, session_id, timeout, on_output}, _from, state) do
    result = await_session_terminal(state, session_id, timeout, on_output)

    case result do
      {:ok, rendered, state} -> {:reply, rendered, state}
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  def handle_call({:close_session, session_id, timeout}, _from, state) do
    with {:ok, state} <- send_body_now(Frames.remote_session_close(session_id), state),
         {:ok, body, state} <-
           await(state, &close_reply?(&1, session_id), timeout) do
      case body do
        {:remote_session_closed, _} ->
          {:reply, :ok, state}

        {:remote_error, info} ->
          {:reply, {:error, remote_error_message(info)}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, transport_error(reason, state)}, state}
    end
  end

  @impl true
  def handle_info(msg, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, msg) do
      {:ok, conn, responses} ->
        {bodies, ws} = decode_responses(responses, state.websocket)
        {:noreply, %{state | conn: conn, websocket: ws, pending: state.pending ++ bodies}}

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
        Connector.connect(state.url, subprotocol: @subprotocol)
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
    hello = Frames.remote_hello(state.token, state.client_instance_id)

    with {:ok, state} <- send_body_now(hello, state),
         {:ok, body, state} <- await(state, &hello_reply?/1, state.connect_timeout) do
      case body do
        {:remote_hello_ok, _info} ->
          {:ok, state}

        {:__closed__, code} ->
          {:error, auth_close_message(code), state}
      end
    else
      {:error, :timeout, state} ->
        {:error,
         "connected to #{state.url} but the broker did not complete the handshake " <>
           "(is the OpenComputers client endpoint enabled on the server?)", state}

      {:error, reason, state} ->
        {:error, transport_error(reason, state), state}
    end
  end

  # ── Synchronous send / receive over the reused Mint socket ───────────────────

  # Wrap the #484 body in the envelope, then encode + send.
  defp send_body_now(_body, %{conn: nil} = state), do: {:error, :not_connected, state}

  defp send_body_now(body, state) do
    bin = FrameCodec.encode(Frames.wrap(body))

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

  # Block until a body satisfies `pred` or the deadline elapses. Server pings are
  # auto-answered and never surface to `pred`. Unmatched bodies stay buffered.
  defp await(state, pred, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(state, pred, deadline, [])
  end

  defp await_loop(state, pred, deadline, seen) do
    case next_body(state, deadline) do
      {:ok, {:ping, seq}, state} ->
        case send_body_now(Frames.pong(seq), state) do
          {:ok, state} -> await_loop(state, pred, deadline, seen)
          {:error, reason, state} -> {:error, reason, restore(state, seen)}
        end

      {:ok, body, state} ->
        if pred.(body) do
          {:ok, body, restore(state, seen)}
        else
          await_loop(state, pred, deadline, [body | seen])
        end

      {:timeout, state} ->
        {:error, :timeout, restore(state, seen)}

      {:error, reason, state} ->
        {:error, reason, restore(state, seen)}
    end
  end

  defp restore(state, seen), do: %{state | pending: state.pending ++ Enum.reverse(seen)}

  # Await the terminal inner host frame for a session, streaming chunks meanwhile.
  defp await_session_terminal(state, session_id, timeout, on_output) do
    deadline = System.monotonic_time(:millisecond) + timeout
    session_terminal_loop(state, session_id, deadline, on_output, [])
  end

  defp session_terminal_loop(state, session_id, deadline, on_output, seen) do
    case next_body(state, deadline) do
      {:ok, {:ping, seq}, state} ->
        case send_body_now(Frames.pong(seq), state) do
          {:ok, state} -> session_terminal_loop(state, session_id, deadline, on_output, seen)
          {:error, reason, state} -> {:error, reason, restore(state, seen)}
        end

      {:ok, body, state} ->
        handle_session_body(state, session_id, deadline, on_output, seen, body)

      {:timeout, state} ->
        {:error, :timeout, restore(state, seen)}

      {:error, reason, state} ->
        {:error, reason, restore(state, seen)}
    end
  end

  defp handle_session_body(state, session_id, deadline, on_output, seen, body) do
    cond do
      match?({:remote_session_frame, %{session_id: ^session_id}}, body) ->
        {:ok, ^session_id, inner} = Frames.unwrap_session_frame(body)

        case Frames.render_session_frame(inner) do
          {:chunk, text} ->
            _ = on_output.(text)
            session_terminal_loop(state, session_id, deadline, on_output, seen)

          {:done, text} ->
            {:ok, {:ok, text}, restore(state, seen)}

          {:fail, text} ->
            {:ok, {:error, text}, restore(state, seen)}

          :ignore ->
            session_terminal_loop(state, session_id, deadline, on_output, seen)
        end

      match?({:remote_session_closed, %{session_id: ^session_id}}, body) ->
        {:remote_session_closed, %{reason: reason}} = body
        {:ok, {:error, "session closed by broker: #{inspect(reason)}"}, restore(state, seen)}

      match?({:remote_error, _}, body) ->
        {:remote_error, info} = body
        {:ok, {:error, remote_error_message(info)}, restore(state, seen)}

      match?({:__closed__, _}, body) ->
        {:__closed__, code} = body
        {:error, {:__closed__, code}, restore(state, seen)}

      true ->
        session_terminal_loop(state, session_id, deadline, on_output, [body | seen])
    end
  end

  defp next_body(%{pending: [body | rest]} = state, _deadline) do
    {:ok, body, %{state | pending: rest}}
  end

  defp next_body(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, state}
    else
      receive do
        msg ->
          case Mint.WebSocket.stream(state.conn, msg) do
            {:ok, conn, responses} ->
              {bodies, ws} = decode_responses(responses, state.websocket)
              state = %{state | conn: conn, websocket: ws, pending: state.pending ++ bodies}

              case state.pending do
                [body | rest] -> {:ok, body, %{state | pending: rest}}
                [] -> next_body(state, deadline)
              end

            {:error, conn, reason, _responses} ->
              {:error, reason, %{state | conn: conn}}

            :unknown ->
              next_body(state, deadline)
          end
      after
        remaining -> {:timeout, state}
      end
    end
  end

  # Decode a batch of Mint responses into a list of unwrapped #484 bodies.
  defp decode_responses(responses, websocket) do
    Enum.reduce(responses, {[], websocket}, fn
      {:data, _ref, data}, {acc, ws} ->
        case Mint.WebSocket.decode(ws, data) do
          {:ok, ws, ws_frames} ->
            bodies =
              Enum.flat_map(ws_frames, fn
                {:binary, bin} ->
                  with {:ok, term} <- FrameCodec.decode(bin),
                       {:ok, body} <- Frames.unwrap(term) do
                    [body]
                  else
                    _ -> []
                  end

                {:close, code, _reason} ->
                  [{:__closed__, code}]

                _other ->
                  []
              end)

            {acc ++ bodies, ws}

          {:error, ws, _reason} ->
            {acc, ws}
        end

      _other, {acc, ws} ->
        {acc, ws}
    end)
  end

  # ── Predicates ───────────────────────────────────────────────────────────────

  defp hello_reply?({:remote_hello_ok, _}), do: true
  defp hello_reply?({:__closed__, _}), do: true
  defp hello_reply?(_), do: false

  defp session_open_reply?({:remote_session_opened, %{ref: r}}, ref), do: r == ref
  defp session_open_reply?({:remote_error, _}, _ref), do: true
  defp session_open_reply?(_, _), do: false

  defp close_reply?({:remote_session_closed, %{session_id: s}}, sid), do: s == sid
  defp close_reply?({:remote_error, _}, _sid), do: true
  defp close_reply?(_, _), do: false

  # ── Messages ─────────────────────────────────────────────────────────────────

  defp unreachable_message(url) do
    "could not reach the OSA remote broker at #{url} " <>
      "(is your MIOSA account linked / is the server reachable?)"
  end

  @doc false
  @spec auth_close_message(integer()) :: String.t()
  def auth_close_message(4003) do
    "MIOSA rejected the account credential for OSA remote: your key lacks the " <>
      "`opencomputers:write` scope. A user key needs `opencomputers:write` (or " <>
      "`opencomputers:admin`); platform keys are always allowed."
  end

  def auth_close_message(4001) do
    "MIOSA rejected the account credential (invalid or inactive key). " <>
      "Re-link with `miosa login`, or check OSA_REMOTE_TOKEN."
  end

  def auth_close_message(code) do
    "MIOSA closed the OSA remote connection during the handshake (code #{code})."
  end

  @doc false
  @spec remote_error_message(map()) :: String.t()
  def remote_error_message(%{reason: reason}) when reason in [:forbidden, "forbidden"] do
    "the host rejected the request (forbidden): your key lacks the " <>
      "`opencomputers:write` scope, or does not own that host."
  end

  def remote_error_message(%{reason: reason}) when reason in [:auth, "auth"] do
    "the broker rejected the account credential (invalid or inactive key)."
  end

  def remote_error_message(%{reason: reason}), do: "remote error: #{describe(reason)}"

  defp transport_error(:timeout, state) do
    "the OSA remote broker at #{state.url} did not respond in time " <>
      "(the host may be offline, or the agent run exceeded the timeout)."
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

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe(reason), do: inspect(reason)

  defp gen_ref, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
