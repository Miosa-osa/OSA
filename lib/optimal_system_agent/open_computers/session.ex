defmodule OptimalSystemAgent.OpenComputers.Session do
  @moduledoc """
  Outbound WSS session to the MIOSA control plane.

  Lifecycle
  ---------
  1. On start, schedules an immediate `:connect` message to itself.
  2. `:connect` calls `Session.Connector.connect/1` and sends hello after a validated upgrade.
  3. After `{:hello_ok, _}` is received (via `Session.FrameRouter.handle/2`),
     transitions to `:active`, registers the host_client and schedules heartbeat timers.
  4. Every `heartbeat_ms` (default 30 s), sends `{:heartbeat, %{ts, seq}}` to
     the control plane.  No response → connection considered dead after
     `@dead_ms` (90 s) of silence; reconnect is triggered.
  5. Transient failures schedule exponential reconnect delays (2 s, 4 s, up to 60 s including jitter).
     Only hello_ok resets the backoff baseline to 1 s.
     Auth, upgrade, fingerprint and revoked-key rejections pause retries until correction and restart.
     All timers are reference-tagged; cancelled or queued timers cannot affect a later attempt.
  6. After `@stuck_threshold` consecutive failures, emits
     `[:osa, :oc, :session, :stuck]` telemetry so an operator can alert.

  `status/0` exposes only phase, safe failure details, failure count and remaining retry delay.
  The CLI consumes this surface without reading the secret-bearing GenServer state.

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
    Failure,
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

  @doc "Safe connection status, including rejection reason/action and remaining retry delay."
  def status, do: GenServer.call(__MODULE__, :status)

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
      hello_timer: nil,
      reconnect_timer: nil,
      failure: nil,
      # reference to the active heartbeat timer
      heartbeat_timer: nil,
      # reference to the inactivity watchdog timer
      dead_timer: nil,
      # heartbeat sequence counter
      heartbeat_seq: 0,
      # heartbeat interval as negotiated in hello_ok (ms)
      heartbeat_ms: 30_000,
      # grant token renewed by control plane (passed along in state)
      grant_token: nil,
      verified_control: false
    }

    {:ok, state}
  end

  # ── Connect ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:status, _from, state) do
    retry_in_ms = if state.reconnect_timer, do: Process.read_timer(state.reconnect_timer) || 0

    {:reply,
     %{
       phase: state.phase,
       failure: state.failure,
       failure_count: state.failure_count,
       retry_in_ms: retry_in_ms
     }, state}
  end

  @impl true
  def handle_info(
        {:timeout, timer, :connect},
        %{phase: :disconnected, reconnect_timer: timer} = state
      ) do
    handle_info(:connect, %{state | reconnect_timer: nil})
  end

  def handle_info({:timeout, _, :connect}, state), do: {:noreply, state}

  def handle_info(:connect, %{phase: :disconnected, reconnect_timer: nil} = state) do
    cfg = Config.get()

    if is_nil(cfg.host_key) or cfg.host_key == "" do
      Logger.info(
        "[OC.Session] host_key not configured — staying disconnected. " <>
          "Run `osa opencomputers login --key <key>` to connect."
      )

      # Retry after a long delay; don't hammer logs.
      {:noreply, schedule_reconnect(%{state | backoff_ms: 60_000})}
    else
      connect_result =
        try do
          Connector.connect(cfg.control_url)
        rescue
          _ -> {:error, :connect_exception}
        catch
          _, _ -> {:error, :connect_exception}
        end

      case connect_result do
        {:ok, {conn, ref, websocket}} ->
          Logger.info("[OC.Session] WS upgrade complete - sending hello")

          state = %{
            state
            | conn: conn,
              ref: ref,
              websocket: websocket,
              phase: :awaiting_hello_ok,
              verified_control: URI.parse(cfg.control_url).scheme == "wss"
          }

          case send_term(state, {:hello, Hello.build(cfg)}) do
            {:ok, state} ->
              timer = :erlang.start_timer(@hello_timeout_ms, self(), :hello_timeout)
              {:noreply, %{state | hello_timer: timer}}

            {:error, reason, state} ->
              Logger.error(
                "[OC.Session] send hello failed reason=#{safe_transport_reason(reason)}"
              )

              new_state = on_failure(close(state))
              {:noreply, schedule_reconnect(new_state)}
          end

        {:error, {:handshake, reason}} ->
          {:noreply, handle_failure(state, Failure.handshake(reason))}

        {:error, reason} ->
          {:noreply, handle_failure(state, Failure.transport(reason))}
      end
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  # ── Hello timeout ─────────────────────────────────────────────────────────────

  def handle_info(
        {:timeout, timer, :hello_timeout},
        %{phase: :awaiting_hello_ok, hello_timer: timer} = state
      ) do
    Logger.warning("[OC.Session] hello_ok timeout — reconnecting")
    new_state = on_failure(close(state))
    {:noreply, schedule_reconnect(new_state)}
  end

  def handle_info(:hello_timeout, state), do: {:noreply, state}
  def handle_info({:timeout, _, :hello_timeout}, state), do: {:noreply, state}

  # ── Self-heartbeat ────────────────────────────────────────────────────────────

  def handle_info(
        {:timeout, timer, :heartbeat},
        %{phase: :active, heartbeat_timer: timer} = state
      ) do
    seq = state.heartbeat_seq + 1

    frame = {:heartbeat, %{ts: DateTime.utc_now() |> DateTime.to_unix(:millisecond), seq: seq}}

    Logger.debug("[OC.Session] phase=active heartbeat_seq=#{seq}")

    case send_term(state, frame) do
      {:ok, state} ->
        timer = :erlang.start_timer(state.heartbeat_ms, self(), :heartbeat)
        {:noreply, %{state | heartbeat_seq: seq, heartbeat_timer: timer}}

      {:error, reason, state} ->
        Logger.warning(
          "[OC.Session] heartbeat send failed reason=#{safe_transport_reason(reason)} - reconnecting"
        )

        new_state = on_failure(close(state))
        {:noreply, schedule_reconnect(new_state)}
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}
  def handle_info({:timeout, _, :heartbeat}, state), do: {:noreply, state}

  # ── Inactivity watchdog ───────────────────────────────────────────────────────

  def handle_info({:timeout, timer, :dead_check}, %{phase: :active, dead_timer: timer} = state) do
    Logger.warning("[OC.Session] no inbound traffic for #{@dead_ms}ms — reconnecting")
    new_state = on_failure(close(state))
    {:noreply, schedule_reconnect(new_state)}
  end

  def handle_info(:dead_check, state), do: {:noreply, state}
  def handle_info({:timeout, _, :dead_check}, state), do: {:noreply, state}

  # ── Outbound frames from executors (via FrameRouter.send_frame/1) ─────────────
  # FrameRouter does: send(host_client_pid, {:send_frame, frame})

  def handle_info({:send_frame, frame}, %{phase: :active} = state) do
    case send_term(state, frame) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        Logger.warning(
          "[OC.Session] send_frame failed reason=#{safe_transport_reason(reason)} - reconnecting"
        )

        new_state = on_failure(close(state))
        {:noreply, schedule_reconnect(new_state)}
    end
  end

  # If not :active (e.g. reconnecting), drop the frame and log.
  def handle_info({:send_frame, frame}, state) do
    Logger.debug("[OC.Session] dropping frame (phase=#{state.phase}): #{inspect(elem(frame, 0))}")
    {:noreply, state}
  end

  # ── Legacy executor_frame path (kept for compatibility) ───────────────────────

  def handle_info({:executor_frame, frame}, %{phase: :active} = state) do
    case send_term(state, frame) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  def handle_info({:executor_frame, _frame}, state), do: {:noreply, state}

  # ── TCP/WS transport messages ─────────────────────────────────────────────────

  def handle_info(msg, state) do
    case handle_transport(msg, state) do
      {:ok, state} ->
        {:noreply, reset_dead_timer(state)}

      {:reconnect, state} ->
        new_state = on_failure(close(state))
        {:noreply, schedule_reconnect(new_state)}

      {:server_close, code, reason, state} ->
        {:noreply, server_close(state, code, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  # ── terminate ─────────────────────────────────────────────────────────────────

  @impl true
  def terminate(_reason, state) do
    OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.SessionGrant.clear(state)

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
              {:server_close, _, _, _} = result -> {:halt, result}
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
              {:server_close, _, _, _} = result -> {:halt, result}
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

      {:close, code, reason}, {:ok, state} ->
        {:halt, {:server_close, code, reason, state}}

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
        cancel_timer(s.hello_timer)
        # Register this pid as host_client for executor outbound frames.
        # Guard with whereis — FrameRouter may not be running in test environments.
        case Process.whereis(GlobalFrameRouter) do
          nil ->
            Logger.warning("[OC.Session] FrameRouter not running — skipping registration")

          _pid ->
            GlobalFrameRouter.register_host_client(self())
        end

        cancel_timer(s.heartbeat_timer)
        timer = :erlang.start_timer(interval_ms, self(), :heartbeat)

        dead = :erlang.start_timer(@dead_ms, self(), :dead_check)
        cancel_timer(s.dead_timer)

        Logger.info("[OC.Session] phase=active heartbeat_interval=#{interval_ms}ms")

        new_s = %{
          s
          | hello_timer: nil,
            heartbeat_timer: timer,
            dead_timer: dead,
            heartbeat_ms: interval_ms,
            backoff_ms: Backoff.initial(),
            failure: nil,
            failure_count: 0
        }

        {:cont, {:ok, new_s}}

      :reconnect, {:ok, s} ->
        {:halt, {:reconnect, s}}

      {:close, code, reason}, {:ok, s} ->
        {:halt, {:server_close, code, reason, s}}

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
    state = OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.SessionGrant.clear(state)
    cancel_timer(state.reconnect_timer)
    cancel_timer(state.hello_timer)
    cancel_timer(state.heartbeat_timer)
    cancel_timer(state.dead_timer)

    if state.conn, do: Mint.HTTP.close(state.conn)

    %{
      state
      | conn: nil,
        ref: nil,
        websocket: nil,
        phase: :disconnected,
        reconnect_timer: nil,
        hello_timer: nil,
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
    cancel_timer(state.reconnect_timer)
    delay = Backoff.with_jitter(state.backoff_ms)
    timer = :erlang.start_timer(delay, self(), :connect)
    %{state | reconnect_timer: timer}
  end

  defp reset_dead_timer(%{phase: :active} = state) do
    cancel_timer(state.dead_timer)
    timer = :erlang.start_timer(@dead_ms, self(), :dead_check)
    %{state | dead_timer: timer}
  end

  defp reset_dead_timer(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp server_close(state, code, _reason), do: handle_failure(state, Failure.close(code))

  defp handle_failure(state, failure) do
    state = %{close(state) | failure: failure}

    if failure.action do
      Logger.error(
        "[OC.Session] #{Failure.describe(failure)}; reconnect paused. #{failure.action}"
      )

      %{state | phase: :rejected}
    else
      state = on_failure(state)

      Logger.warning(
        "[OC.Session] #{Failure.describe(failure)} - retrying in ~#{state.backoff_ms}ms"
      )

      schedule_reconnect(state)
    end
  end

  defp safe_transport_reason(reason), do: Failure.transport_reason(reason)
end
