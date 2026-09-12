defmodule OptimalSystemAgent.OpenComputers.Session.Connector do
  @moduledoc """
  Establishes the Mint HTTP connection + WebSocket upgrade to the
  MIOSA control plane.

  Pure orchestration — delegates to `Mint.HTTP`, `Mint.WebSocket`,
  and `Session.TlsOpts`.
  """

  alias OptimalSystemAgent.OpenComputers.Session.TlsOpts

  @subprotocol "miosa-opencomputers-v1"
  @upgrade_timeout_ms 5_000

  @type t :: {Mint.HTTP.t(), reference(), Mint.WebSocket.t()}

  @doc """
  Connect and upgrade to the control-plane WebSocket.

  The host side uses the default `#{@subprotocol}` subprotocol. The remote
  CLIENT side passes `subprotocol: "miosa-opencomputers-client-v1"` so it
  negotiates the #484 client endpoint.
  The response must select exactly that subprotocol and return HTTP 101.
  Deploy the backend's selected-subprotocol response-header fix before releasing this validation.
  Upgrade failures close the owned connection and return safe handshake categories.
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(control_url, opts \\ []) when is_binary(control_url) and is_list(opts) do
    subprotocol = Keyword.get(opts, :subprotocol, @subprotocol)
    uri = URI.parse(control_url)
    scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    port = uri.port || if scheme == :https, do: 443, else: 80
    path = uri.path || "/"

    transport_opts = if scheme == :https, do: TlsOpts.build(), else: []

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, port,
             protocols: [:http1],
             transport_opts: transport_opts
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [
             {"sec-websocket-protocol", subprotocol}
           ]),
         {:ok, conn, websocket} <-
           await_upgrade(conn, ref, subprotocol, nil, now() + @upgrade_timeout_ms) do
      {:ok, {conn, ref, websocket}}
    else
      {:error, reason} -> {:error, reason}
      {:error, conn, reason} -> fail(conn, reason)
    end
  end

  # ── Private ──

  defp await_upgrade(conn, ref, subprotocol, status, deadline) do
    socket = Mint.HTTP.get_socket(conn)
    remaining = max(deadline - now(), 0)

    receive do
      message
      when is_tuple(message) and tuple_size(message) in [2, 3] and
             elem(message, 1) == socket and
             elem(message, 0) in [:tcp, :ssl, :tcp_closed, :ssl_closed, :tcp_error, :ssl_error] ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case upgrade_response(conn, ref, responses, subprotocol, status) do
              {:waiting, conn, status} -> await_upgrade(conn, ref, subprotocol, status, deadline)
              result -> result
            end

          # Mint may mark the returned connection closed before closing its socket.
          # Close the owned, pre-stream connection so the transport is released.
          {:error, _closed_conn, _reason, _responses} ->
            fail(conn, :upgrade_transport_error)

          :unknown ->
            await_upgrade(conn, ref, subprotocol, status, deadline)
        end
    after
      remaining -> fail(conn, :upgrade_timeout)
    end
  end

  defp upgrade_response(conn, ref, responses, subprotocol, status) do
    Enum.reduce_while(responses, {:waiting, conn, status}, fn
      {:status, ^ref, status}, {:waiting, conn, _} when status != 101 ->
        {:halt, fail(conn, {:handshake, {:http_status, status}})}

      {:status, ^ref, 101}, {:waiting, conn, _} ->
        {:cont, {:waiting, conn, 101}}

      {:headers, ^ref, headers}, {:waiting, conn, status} ->
        result =
          if for({"sec-websocket-protocol", value} <- headers, do: value) == [subprotocol] do
            case Mint.WebSocket.new(conn, ref, status, headers) do
              {:error, conn, _reason} -> {:error, conn, {:handshake, :invalid_upgrade}}
              result -> result
            end
          else
            {:error, conn, {:handshake, :subprotocol_mismatch}}
          end

        case result do
          {:ok, conn, websocket} ->
            {:halt, {:ok, conn, websocket}}

          {:error, conn, reason} ->
            {:halt, fail(conn, reason)}
        end

      {:done, ^ref}, {:waiting, conn, _} ->
        {:halt, fail(conn, {:handshake, :invalid_upgrade})}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp fail(conn, reason) do
    Mint.HTTP.close(conn)
    {:error, reason}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
