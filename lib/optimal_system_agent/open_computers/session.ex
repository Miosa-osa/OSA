defmodule OptimalSystemAgent.OpenComputers.Session do
  @moduledoc """
  Outbound-only WSS session to the MIOSA control plane.

  Thin lifecycle GenServer. All real work delegates to focused siblings:

    * `Session.Connector`   — Mint connect + WS upgrade
    * `Session.FrameCodec`  — erlterm encode/decode
    * `Session.Hello`       — build the hello frame
    * `Session.Fingerprint` — ed25519 load/generate
    * `Session.FrameRouter` — dispatch inbound frames
    * `Session.Backoff`     — exponential reconnect delay
    * `Session.TlsOpts`     — TLS configuration

  Owns only state transitions between `:disconnected`,
  `:awaiting_hello_ok`, and `:active`.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.Config
  alias OptimalSystemAgent.OpenComputers.Session.{Backoff, Connector, FrameCodec, FrameRouter, Hello}

  @hello_timeout_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :connect)

    state = %{
      conn: nil,
      ref: nil,
      websocket: nil,
      phase: :disconnected,
      backoff_ms: Backoff.initial()
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    cfg = Config.get()

    cond do
      is_nil(cfg.host_key) or cfg.host_key == "" ->
        Logger.warning("[OpenComputers.Session] host_key not configured — staying disconnected")
        schedule_reconnect(state)
        {:noreply, state}

      true ->
        case Connector.connect(cfg.control_url) do
          {:ok, {conn, ref, websocket}} ->
            Logger.info("[OpenComputers.Session] WS upgrade complete — sending hello")

            state = %{
              state
              | conn: conn,
                ref: ref,
                websocket: websocket,
                phase: :awaiting_hello_ok,
                backoff_ms: Backoff.initial()
            }

            case send_term(state, {:hello, Hello.build(cfg)}) do
              {:ok, state} ->
                Process.send_after(self(), :hello_timeout, @hello_timeout_ms)
                {:noreply, state}

              {:error, reason, state} ->
                Logger.error("[OpenComputers.Session] send hello failed: #{inspect(reason)}")
                schedule_reconnect(state)
                {:noreply, close(state)}
            end

          {:error, reason} ->
            Logger.warning("[OpenComputers.Session] connect failed: #{inspect(reason)} — retrying in ~#{state.backoff_ms}ms")
            schedule_reconnect(state)
            {:noreply, %{state | backoff_ms: Backoff.next(state.backoff_ms)}}
        end
    end
  end

  def handle_info(:hello_timeout, %{phase: :awaiting_hello_ok} = state) do
    Logger.warning("[OpenComputers.Session] hello timeout — reconnecting")
    schedule_reconnect(state)
    {:noreply, close(state)}
  end

  def handle_info(:hello_timeout, state), do: {:noreply, state}

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info({:executor_frame, frame}, state) do
    case send_term(state, frame) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    case handle_transport(msg, state) do
      {:ok, state} ->
        {:noreply, state}

      {:reconnect, state} ->
        schedule_reconnect(state)
        {:noreply, close(state)}

      :unknown ->
        {:noreply, state}
    end
  end

  # ── Transport I/O ──

  defp send_term(state, term) do
    bin = FrameCodec.encode(term)

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

  defp handle_transport(msg, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, msg) do
      {:ok, conn, responses} -> handle_responses(responses, %{state | conn: conn})
      {:error, _conn, _reason, _responses} -> {:reconnect, state}
      :unknown -> :unknown
    end
  end

  defp handle_transport(_, _), do: :unknown

  defp handle_responses(responses, state) do
    Enum.reduce_while(responses, {:ok, state}, fn
      {:data, _ref, data}, {:ok, state} ->
        case Mint.WebSocket.decode(state.websocket, data) do
          {:ok, websocket, frames} -> handle_frames(frames, %{state | websocket: websocket})
          {:error, websocket, _reason} -> {:halt, {:reconnect, %{state | websocket: websocket}}}
        end

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp handle_frames(frames, state) do
    Enum.reduce_while(frames, {:ok, state}, fn
      {:binary, bin}, {:ok, state} ->
        case FrameCodec.decode(bin) do
          {:ok, term} ->
            {actions, state} = FrameRouter.handle(term, state)
            apply_actions(actions, state)

          :error ->
            {:cont, {:ok, state}}
        end

      {:close, _code, _reason}, {:ok, state} ->
        {:halt, {:reconnect, state}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp apply_actions(actions, state) do
    Enum.reduce_while(actions, {:ok, state}, fn
      {:send, term}, {:ok, s} ->
        case send_term(s, term) do
          {:ok, s} -> {:cont, {:cont, {:ok, s}}}
          {:error, _reason, s} -> {:halt, {:halt, {:reconnect, s}}}
        end

      {:start_heartbeat, interval_ms}, {:ok, s} ->
        Process.send_after(self(), :heartbeat, interval_ms)
        {:cont, {:cont, {:ok, s}}}

      :reconnect, {:ok, s} ->
        {:halt, {:halt, {:reconnect, s}}}

      :noop, acc ->
        {:cont, {:cont, acc}}
    end)
    |> case do
      {:cont, acc} -> acc
      {:halt, result} -> result
      acc -> acc
    end
  end

  defp close(state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    %{state | conn: nil, ref: nil, websocket: nil, phase: :disconnected}
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, Backoff.with_jitter(state.backoff_ms))
  end
end
