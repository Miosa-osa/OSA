defmodule OptimalSystemAgent.OpenComputers.Remote.Client do
  @moduledoc """
  Synchronous WebSocket client for a user's OpenComputers remote session.

  This client deliberately keeps the account key in memory only.
  `OptimalSystemAgent.MIOSA.Platform` resolves it from `miosa login` or
  `MIOSA_PLATFORM_API_KEY`; this module never writes it to OSA config files.

  Each invocation owns one WebSocket connection and is responsible for closing
  it.  That makes the non-interactive CLI commands deterministic.  Interactive
  shell mode keeps the same connection open and consumes frames through
  `receive_frames/3`.
  """

  alias OptimalSystemAgent.OpenComputers.Remote.Protocol
  alias OptimalSystemAgent.OpenComputers.Session.{Connector, FrameCodec}

  @default_url "wss://api.miosa.ai/api/v1/opencomputers/clients/ws"
  @timeout_ms 15_000
  @protocol_version 1
  @subprotocol "miosa-opencomputers-client-v1"

  defstruct [:conn, :ref, :websocket, :url]

  @type t :: %__MODULE__{
          conn: Mint.HTTP.t(),
          ref: reference(),
          websocket: Mint.WebSocket.t(),
          url: String.t()
        }

  @doc "Connect and authenticate a short-lived remote client session."
  @spec connect(keyword()) :: {:ok, t()} | {:error, term()}
  def connect(opts \\ []) do
    url = Keyword.get(opts, :url, @default_url)
    key = Keyword.fetch!(opts, :account_key)

    with {:ok, {conn, ref, websocket}} <- Connector.connect(url, subprotocol: @subprotocol),
         {:ok, client, {:remote_hello_ok, _}} <-
           request(
             %__MODULE__{conn: conn, ref: ref, websocket: websocket, url: url},
             {:remote_hello, %{account_key: key, client_instance_id: Ecto.UUID.generate()}},
             &match?({:remote_hello_ok, _}, &1),
             Keyword.get(opts, :timeout, @timeout_ms)
           ) do
      {:ok, client}
    end
  end

  @doc "Send one remote protocol body and wait for the first matching response body."
  @spec request(t(), term(), (term() -> boolean()), timeout()) ::
          {:ok, t(), term()} | {:error, term()}
  def request(%__MODULE__{} = client, frame, matcher, timeout \\ @timeout_ms)
      when is_function(matcher, 1) do
    with :ok <- validate_outgoing(frame),
         {:ok, client} <- send_frame(client, Protocol.envelope(frame)) do
      receive_frames(client, matcher, timeout)
    end
  end

  @doc "Write one already-enveloped protocol term without waiting for a reply."
  @spec send_frame(t(), term()) :: {:ok, t()} | {:error, term()}
  def send_frame(%__MODULE__{} = client, term) do
    bin = FrameCodec.encode(term)

    case Mint.WebSocket.encode(client.websocket, {:binary, bin}) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(client.conn, client.ref, data) do
          {:ok, conn} -> {:ok, %{client | conn: conn, websocket: websocket}}
          {:error, _conn, reason} -> {:error, reason}
        end

      {:error, _websocket, reason} ->
        {:error, reason}
    end
  end

  @doc "Receive frames until `matcher` accepts one, replying to wire pings."
  @spec receive_frames(t(), (term() -> boolean()), timeout()) ::
          {:ok, t(), term()} | {:error, term()}
  def receive_frames(%__MODULE__{} = client, matcher, timeout \\ @timeout_ms)
      when is_function(matcher, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_until(client, matcher, deadline)
  end

  @doc "Best-effort close."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = client) do
    _ = Mint.HTTP.close(client.conn)
    :ok
  end

  defp receive_until(client, matcher, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        message ->
          case Mint.WebSocket.stream(client.conn, message) do
            {:ok, conn, responses} ->
              case decode_responses(%{client | conn: conn}, responses, matcher) do
                {:match, client, frame} -> {:ok, client, frame}
                {:continue, client} -> receive_until(client, matcher, deadline)
                {:error, reason} -> {:error, reason}
              end

            {:error, _conn, reason, _responses} ->
              {:error, reason}

            :unknown ->
              receive_until(client, matcher, deadline)
          end
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp decode_responses(client, responses, matcher) do
    Enum.reduce_while(responses, {:continue, client}, fn
      {:data, _ref, data}, {:continue, client} ->
        case Mint.WebSocket.decode(client.websocket, data) do
          {:ok, websocket, frames} ->
            client = %{client | websocket: websocket}

            case decode_frames(client, frames, matcher) do
              {:continue, client} -> {:cont, {:continue, client}}
              other -> {:halt, other}
            end

          {:error, _websocket, reason} ->
            {:halt, {:error, reason}}
        end

      {:done, _ref}, acc ->
        {:cont, acc}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp decode_frames(client, frames, matcher) do
    Enum.reduce_while(frames, {:continue, client}, fn
      {:binary, bin}, {:continue, client} ->
        case FrameCodec.decode(bin) do
          {:ok, {:oc_remote, %{v: @protocol_version, body: {:ping, seq}}}} ->
            case send_frame(client, Protocol.envelope({:pong, seq})) do
              {:ok, client} -> {:cont, {:continue, client}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, envelope} ->
            case Protocol.unwrap(envelope) do
              {:ok, frame} when is_tuple(frame) ->
                if matcher.(frame) do
                  {:halt, {:match, client, frame}}
                else
                  {:cont, {:continue, client}}
                end

              _ ->
                {:halt, {:error, :invalid_envelope}}
            end

          {:ok, _invalid_envelope} ->
            {:halt, {:error, :invalid_envelope}}

          :error ->
            {:halt, {:error, :invalid_frame}}
        end

      {:ping, _}, {:continue, client} ->
        {:cont, {:continue, client}}

      {:close, code, reason}, _acc ->
        {:halt, {:error, {:closed, code, reason}}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp validate_outgoing(body),
    do: if(Protocol.client_body?(body), do: :ok, else: {:error, :invalid_client_operation})
end
