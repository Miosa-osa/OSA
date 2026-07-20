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
  negotiates the #484 client endpoint. All other callers are unchanged.
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
         {:ok, conn, websocket} <- await_upgrade(conn, ref) do
      {:ok, {conn, ref, websocket}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  # ── Private ──

  defp await_upgrade(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} -> upgrade_response(conn, ref, responses)
          {:error, _conn, reason, _responses} -> {:error, reason}
          :unknown -> await_upgrade(conn, ref)
        end
    after
      @upgrade_timeout_ms -> {:error, :upgrade_timeout}
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
      {:ok, conn, websocket} -> {:ok, conn, websocket}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_upgrade}
    end
  end
end
