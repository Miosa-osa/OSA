defmodule OptimalSystemAgent.OpenComputers.Session do
  @moduledoc """
  Outbound WSS session to the MIOSA control plane.

  Lifecycle
  ---------
  1. On start, schedules an immediate `:connect` message to itself.
  2. `:connect` — calls `Session.Connector.connect/1` (blocking Mint upgrade),
     on success sends the `{:hello, ...}` frame and registers itself as the
     active host_client in `OpenComputers.FrameRouter` so executor outbound
     frames reach the wire.
  3. After `{:hello_ok, _}` is received (via `Session.FrameRouter.handle/2`),
     transitions to `:active` and schedules a self-heartbeat timer.
  4. Every `heartbeat_ms` (default 30 s), sends `{:heartbeat, %{ts, seq}}` to
     the control plane.  No response → connection considered dead after
     `@dead_ms` (90 s) of silence; reconnect is triggered.
  5. On any transport error or explicit `{:close, _, _}` frame, resets to
     `:disconnected` and schedules a reconnect with exponential backoff
     (1 s → 2 s → … → 60 s, ±200 ms jitter, reset to 1 s on success).
  6. After `@stuck_threshold` consecutive failures, emits
     `[:osa, :oc, :session, :stuck]` telemetry so an operator can alert.

  Outbound frame path
  -------------------
  Executors (Pty, Desktop.Controller, Updater) call
  `OpenComputers.FrameRouter.send_frame/1`.  That GenServer looks up the
  registered Session pid and does `send(pid, {:send_frame, frame})`.  Session
  handles those messages in `handle_info/2` and writes them to the wire via
  `send_term/2`.

  Inbound frame path
  ------------------
  TCP data → `Mint.WebSocket.stream/2` → `Mint.WebSocket.decode/2` →
  `FrameCodec.decode/1` → `Session.FrameRouter.handle/2` (returns actions) →
  `apply_actions/2`.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.Config
  alias OptimalSystemAgent.OpenComputers.FrameRouter, as: GlobalFrameRouter

  alias OptimalSystemAgent.OpenComputers.Session.{
    Backoff,
    Connector,
    FrameCodec,
    FrameRouter,
    Hello
  }

  @hello_timeout_ms 5_000
  # 90 seconds without any inbound traffic → force reconnect
  @dead_ms 90_000
  # Number of consecutive connect failures before emitting :stuck telemetry
  @stuck_threshold 10

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer init ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    send(self(), :connect)

    state = %{
      conn: nil,
      ref: nil,
      websocket: nil,
      phase: :disconnected,
      backoff_ms: Backoff.initial(),
      # consecutive connect failures (reset on successful hello_ok)
      failure_count: 0,
      # reference to the active heartbeat timer (Process.send_after)
      heartbeat_timer: nil,
      # reference to the inactivity watchdog timer
      dead_timer: nil,
      # heartbeat sequence counter
      heartbeat_seq: 0,
      # heartbeat interval as negotiated in hello_ok (ms)
      heartbeat_ms: 30_000,
      # grant token renewed by control plane (passed along in state)
      grant_token: nil
    }

    {:ok, state}
  end

  # ── Connect ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:connect, state) do
    cfg = Config.get()

    if is_nil(cfg.host_key) or cfg.host_key == "" do
      Logger.info(
        "[OC.Session] host_key not configured — staying disconnected. " <>
          "Run `osa opencomputers login --key <key>` to connect."
      )

      # Retry after a long delay; don't hammer logs.
      schedule_reconnect(%{state | backoff_ms: 60_000})
      {:noreply, state}
    else
      connect_result =
        try do
          Connector.connect(cfg.control_url)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case connect_result do
        {:ok, {conn, ref, websocket}} ->
          Logger.info(
            "[OC.Session] WS upgrade complete — sending hello host_key=#{redact(cfg.host_key)}"
          )

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
              Logger.error("[OC.Session] send hello failed: #{inspect(reason)}")
              new_state = on_failure(close(state))
              schedule_reconnect(new_state)
              {:noreply, new_state}
          end

        {:error, reason} ->
          new_state = on_failure(state)

          Logger.warning(
            "[OC.Session] connect failed (attempt=#{new_state.failure_count}): " <>
              "#{inspect(reason)} — retrying in ~#{new_state.backoff_ms}ms"
          )

          schedule_reconnect(new_state)
          {:noreply, new_state}
      end
    end
  end

  # ── Hello timeout ─────────────────────────────────────────────────────────────

  def handle_info(:hello_timeout, %{phase: :awaiting_hello_ok} = state) do
    Logger.warning("[OC.Session] hello_ok timeout — reconnecting")
    new_state = on_failure(close(state))
    schedule_reconnect(new_state)
    {:noreply, new_state}
  end

  def handle_info(:hello_timeout, state), do: {:noreply, state}

  # ── Self-heartbeat ────────────────────────────────────────────────────────────

  def handle_info(:heartbeat, %{phase: :active} = state) do
    seq = state.heartbeat_seq + 1

    frame = {:heartbeat, %{ts: DateTime.utc_now() |> DateTime.to_unix(:millisecond), seq: seq}}

    Logger.debug("[OC.Session] phase=active heartbeat_seq=#{seq}")

    case send_term(state, frame) do
      {:ok, state} ->
        timer = Process.send_after(self(), :heartbeat, state.heartbeat_ms)
        {:noreply, %{state | heartbeat_seq: seq, heartbeat_timer: timer}}

      {:error, reason, state} ->
        Logger.warning("[OC.Session] heartbeat send failed: #{inspect(reason)} — reconnecting")
        new_state = on_failure(close(state))
        schedule_reconnect(new_state)
        {:noreply, new_state}
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  # ── Inactivity watchdog ───────────────────────────────────────────────────────

  def handle_info(:dead_check, %{phase: :active} = state) do
    Logger.warning("[OC.Session] no inbound traffic for #{@dead_ms}ms — reconnecting")
    new_state = on_failure(close(state))
    schedule_reconnect(new_state)
    {:noreply, new_state}
  end

  def handle_info(:dead_check, state), do: {:noreply, state}

  # ── Outbound frames from executors (via FrameRouter.send_frame/1) ─────────────
  # FrameRouter does: send(host_client_pid, {:send_frame, frame})

  def handle_info({:send_frame, frame}, %{phase: :active} = state) do
    case send_term(state, frame) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        Logger.warning("[OC.Session] send_frame failed: #{inspect(reason)} — reconnecting")
        new_state = on_failure(close(state))
        schedule_reconnect(new_state)
        {:noreply, new_state}
    end
  end

  # If not :active (e.g. reconnecting), drop the frame and log.
  def handle_info({:send_frame, frame}, state) do
    Logger.debug("[OC.Session] dropping frame (phase=#{state.phase}): #{inspect(elem(frame, 0))}")
    {:noreply, state}
  end

  # ── Legacy executor_frame path (kept for compatibility) ───────────────────────

  def handle_info({:executor_frame, frame}, state) do
    case send_term(state, frame) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  # ── TCP/WS transport messages ─────────────────────────────────────────────────

  def handle_info(msg, state) do
    case handle_transport(msg, state) do
      {:ok, state} ->
        {:noreply, reset_dead_timer(state)}

      {:reconnect, state} ->
        new_state = on_failure(close(state))
        schedule_reconnect(new_state)
        {:noreply, new_state}

      :unknown ->
        {:noreply, state}
    end
  end

  # ── terminate ─────────────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, state) do
    if state.conn do
      # Best-effort: send a WS close frame before the connection drops.
      case Mint.WebSocket.encode(state.websocket, :close) do
        {:ok, _ws, data} ->
          Mint.WebSocket.stream_request_body(state.conn, state.ref, data)

        _ ->
          :ok
      end

      Mint.HTTP.close(state.conn)
    end

    :ok
  end

  # ── Transport helpers ─────────────────────────────────────────────────────────

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
          {:ok, websocket, frames} ->
            case handle_frames(frames, %{state | websocket: websocket}) do
              {:ok, new_state} -> {:cont, {:ok, new_state}}
              {:reconnect, new_state} -> {:halt, {:reconnect, new_state}}
            end

          {:error, websocket, _reason} ->
            {:halt, {:reconnect, %{state | websocket: websocket}}}
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

            case apply_actions(actions, state) do
              {:ok, new_state} -> {:cont, {:ok, new_state}}
              {:reconnect, new_state} -> {:halt, {:reconnect, new_state}}
            end

          :error ->
            {:cont, {:ok, state}}
        end

      {:ping, _data}, {:ok, state} ->
        # Respond to WS-level pings with a pong
        case send_term(state, {:pong, nil}) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, _reason, state} -> {:halt, {:reconnect, state}}
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
          {:ok, s} -> {:cont, {:ok, s}}
          {:error, _reason, s} -> {:halt, {:reconnect, s}}
        end

      {:start_heartbeat, interval_ms}, {:ok, s} ->
        # Register this pid as host_client for executor outbound frames.
        # Guard with whereis — FrameRouter may not be running in test environments.
        case Process.whereis(GlobalFrameRouter) do
          nil ->
            Logger.warning("[OC.Session] FrameRouter not running — skipping registration")

          _pid ->
            GlobalFrameRouter.register_host_client(self())
        end

        cancel_timer(s.heartbeat_timer)
        timer = Process.send_after(self(), :heartbeat, interval_ms)

        dead = Process.send_after(self(), :dead_check, @dead_ms)
        cancel_timer(s.dead_timer)

        Logger.info("[OC.Session] phase=active heartbeat_interval=#{interval_ms}ms")

        new_s = %{
          s
          | heartbeat_timer: timer,
            dead_timer: dead,
            heartbeat_ms: interval_ms,
            failure_count: 0
        }

        {:cont, {:ok, new_s}}

      :reconnect, {:ok, s} ->
        {:halt, {:reconnect, s}}

      :noop, acc ->
        {:cont, acc}
    end)
    |> case do
      {:cont, acc} -> acc
      {:halt, result} -> result
      acc -> acc
    end
  end

  # ── State helpers ─────────────────────────────────────────────────────────────

  defp close(state) do
    cancel_timer(state.heartbeat_timer)
    cancel_timer(state.dead_timer)

    if state.conn, do: Mint.HTTP.close(state.conn)

    %{
      state
      | conn: nil,
        ref: nil,
        websocket: nil,
        phase: :disconnected,
        heartbeat_timer: nil,
        dead_timer: nil
    }
  end

  defp on_failure(state) do
    count = state.failure_count + 1
    next_backoff = Backoff.next(state.backoff_ms)

    if count == @stuck_threshold do
      :telemetry.execute(
        [:osa, :oc, :session, :stuck],
        %{failure_count: count, backoff_ms: next_backoff},
        %{}
      )

      Logger.error(
        "[OC.Session] #{count} consecutive connect failures — emitting :stuck telemetry"
      )
    end

    %{state | failure_count: count, backoff_ms: next_backoff}
  end

  defp schedule_reconnect(state) do
    delay = Backoff.with_jitter(state.backoff_ms)
    Process.send_after(self(), :connect, delay)
  end

  defp reset_dead_timer(state) do
    cancel_timer(state.dead_timer)
    timer = Process.send_after(self(), :dead_check, @dead_ms)
    %{state | dead_timer: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp redact(nil), do: "(nil)"
  defp redact(key) when byte_size(key) > 8, do: binary_part(key, 0, 7) <> "..."
  defp redact(key), do: key
end
