defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Relay do
  @moduledoc """
  Bidirectional bridge between a local TCP socket (x11vnc RFB) and
  a MIOSA relay WebSocket.

  Lifecycle:
    1. `open/2` — connect Mint WebSocket to the relay URL.
    2. `connect_tcp/1` — open a plain TCP socket to localhost:<vnc_port>.
    3. `loop/3` — pump bytes in both directions until either side closes.

  The caller is responsible for cleanup (close/kill) when the loop exits.
  The loop sends `{:relay_done, reason}` to `notify_pid` when it stops.
  """

  require Logger

  alias OptimalSystemAgent.OpenComputers.Session.TlsOpts

  @connect_timeout_ms 10_000
  @ws_recv_timeout_ms 50

  @type ws_conn :: {Mint.HTTP.t(), reference(), Mint.WebSocket.t()}

  @doc "Open a Mint WebSocket to relay_url. Returns {:ok, ws_conn} or {:error, reason}."
  @spec open(String.t()) :: {:ok, ws_conn()} | {:error, term()}
  def open(relay_url) when is_binary(relay_url) do
    uri = URI.parse(relay_url)
    scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    port = uri.port || if scheme == :https, do: 443, else: 80
    path = build_path(uri)

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, port,
             protocols: [:http1],
             transport_opts: TlsOpts.build()
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, []),
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      {:ok, {conn, ref, websocket}}
    else
      {:error, reason} -> {:error, {:ws_connect_failed, reason}}
      {:error, _conn, reason} -> {:error, {:ws_connect_failed, reason}}
    end
  end

  @doc "Open a TCP socket to localhost:<vnc_port>."
  @spec connect_tcp(non_neg_integer()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect_tcp(vnc_port) when is_integer(vnc_port) and vnc_port > 0 do
    case :gen_tcp.connect(
           ~c"127.0.0.1",
           vnc_port,
           [:binary, active: false, packet: :raw, nodelay: true],
           @connect_timeout_ms
         ) do
      {:ok, sock} -> {:ok, sock}
      {:error, reason} -> {:error, {:tcp_connect_failed, reason}}
    end
  end

  @doc """
  Pump bytes between tcp_sock and ws_conn until either side closes.
  Sends `{:relay_done, reason}` to notify_pid on exit.
  Runs in the caller's process — call from a dedicated Task/GenServer.
  """
  @spec loop(:gen_tcp.socket(), ws_conn(), pid()) :: :ok
  def loop(tcp_sock, {conn, ref, websocket}, notify_pid) do
    # Set TCP to active so we get messages into the receive loop
    :ok = :inet.setopts(tcp_sock, active: :once)
    do_loop(tcp_sock, conn, ref, websocket, notify_pid)
  end

  # ── Private ──

  defp do_loop(tcp_sock, conn, ref, websocket, notify_pid) do
    receive do
      # ── TCP → WebSocket ──────────────────────────────────────────────
      {:tcp, ^tcp_sock, data} ->
        case send_ws_binary(conn, ref, websocket, data) do
          {:ok, conn, websocket} ->
            :ok = :inet.setopts(tcp_sock, active: :once)
            do_loop(tcp_sock, conn, ref, websocket, notify_pid)

          {:error, reason} ->
            Logger.warning("[Relay] WS send failed: #{inspect(reason)}")
            send(notify_pid, {:relay_done, {:ws_send_error, reason}})
        end

      {:tcp_closed, ^tcp_sock} ->
        Logger.debug("[Relay] TCP socket closed (x11vnc side)")
        send(notify_pid, {:relay_done, :tcp_closed})

      {:tcp_error, ^tcp_sock, reason} ->
        Logger.warning("[Relay] TCP error: #{inspect(reason)}")
        send(notify_pid, {:relay_done, {:tcp_error, reason}})

      # ── WebSocket → TCP ──────────────────────────────────────────────
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, responses} ->
            case handle_ws_responses(responses, ref, websocket, tcp_sock) do
              {:ok, websocket} ->
                do_loop(tcp_sock, conn, ref, websocket, notify_pid)

              {:close, _reason} ->
                Logger.debug("[Relay] WS closed by remote")
                send(notify_pid, {:relay_done, :ws_closed})

              {:error, reason} ->
                Logger.warning("[Relay] WS response error: #{inspect(reason)}")
                send(notify_pid, {:relay_done, {:ws_error, reason}})
            end

          {:error, _conn, reason, _} ->
            Logger.warning("[Relay] Mint stream error: #{inspect(reason)}")
            send(notify_pid, {:relay_done, {:ws_stream_error, reason}})

          :unknown ->
            # Not a Mint message — ignore
            do_loop(tcp_sock, conn, ref, websocket, notify_pid)
        end
    after
      @ws_recv_timeout_ms ->
        # Re-arm TCP active and loop
        :ok = :inet.setopts(tcp_sock, active: :once)
        do_loop(tcp_sock, conn, ref, websocket, notify_pid)
    end
  end

  defp send_ws_binary(conn, ref, websocket, data) do
    with {:ok, websocket, frame} <- Mint.WebSocket.encode(websocket, {:binary, data}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, frame) do
      {:ok, conn, websocket}
    else
      {:error, _ws, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_ws_responses(responses, ref, websocket, tcp_sock) do
    Enum.reduce_while(responses, {:ok, websocket}, fn
      {:data, ^ref, data}, {:ok, ws} ->
        case Mint.WebSocket.decode(ws, data) do
          {:ok, ws, frames} ->
            case forward_frames(frames, tcp_sock) do
              :ok -> {:cont, {:ok, ws}}
              {:close, reason} -> {:halt, {:close, reason}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, _ws, reason} ->
            {:halt, {:error, reason}}
        end

      {:done, ^ref}, _acc ->
        {:halt, {:close, :done}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp forward_frames(frames, tcp_sock) do
    Enum.reduce_while(frames, :ok, fn
      {:binary, payload}, :ok ->
        case :gen_tcp.send(tcp_sock, payload) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:tcp_send_failed, reason}}}
        end

      {:text, payload}, :ok ->
        case :gen_tcp.send(tcp_sock, payload) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:tcp_send_failed, reason}}}
        end

      {:close, _code, _reason}, :ok ->
        {:halt, {:close, :remote_close}}

      {:ping, data}, :ok ->
        # pong is handled by Mint.WebSocket internally; nothing to forward
        _ = data
        {:cont, :ok}

      _other, acc ->
        {:cont, acc}
    end)
  end

  # ── Upgrade helpers ──

  defp build_path(%URI{path: nil, query: nil}), do: "/"
  defp build_path(%URI{path: path, query: nil}), do: path || "/"
  defp build_path(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

  defp await_upgrade(conn, ref) do
    receive do
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, responses} -> upgrade_response(conn, ref, responses)
          {:error, _conn, reason, _} -> {:error, reason}
          :unknown -> await_upgrade(conn, ref)
        end
    after
      @connect_timeout_ms -> {:error, :upgrade_timeout}
    end
  end

  defp upgrade_response(conn, ref, responses) do
    Enum.reduce_while(responses, {:waiting, conn}, fn
      {:status, ^ref, _status}, {:waiting, conn} ->
        {:cont, {:waiting, conn}}

      {:headers, ^ref, headers}, {:waiting, conn} ->
        case Mint.WebSocket.new(conn, ref, 101, headers) do
          {:ok, conn, websocket} -> {:halt, {:ok, conn, websocket}}
          {:error, _conn, reason} -> {:halt, {:error, reason}}
        end

      {:done, ^ref}, acc ->
        {:halt, acc}

      _other, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, conn, ws} -> {:ok, conn, ws}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_upgrade}
    end
  end
end
