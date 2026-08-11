defmodule OptimalSystemAgent.Monitor.WatchTask do
  @moduledoc """
  A single supervised background watcher.

  MECHANISM (not interface): this GenServer owns one watch registered by the
  `monitor` tool. It re-samples its target on a self-scheduled `:poll` timer
  (non-blocking — the agent's ReAct turn is NOT held while it runs) and, on each
  detected change (or when an optional `condition` becomes true), it:

    * emits `{:system_event, event: :monitor_fired, ...}` on the `Events.Bus`
      (bridged to the session's `osa:session:<id>` PubSub topic by
      `Events.TuiForwarder`, whose allowlist already includes `monitor_fired`),
      and
    * injects a synthetic user message into the parent `Agent.Loop` via
      `Loop.inject_agent_result/2` so the model sees the change at its next step
      boundary — the same re-entry mechanism background shell commands use.

  Modes:
    * `:once`   — fire once, then retire (backward-compatible default).
    * `:repeat` — keep watching and fire on every subsequent occurrence until
      `duration_seconds` elapses or `max_fires` is reached.

  The watcher is registered by its watch id in
  `OptimalSystemAgent.Monitor.WatchRegistry` so callers can look it up, poll it,
  or stop it (see `OptimalSystemAgent.Monitor.WatchManager`).
  """

  use GenServer, restart: :temporary

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Tools.Builtins.Monitor.Constants

  @registry OptimalSystemAgent.Monitor.WatchRegistry

  defstruct [
    :id,
    :input,
    :session_id,
    :kind,
    :target,
    :mode,
    :condition,
    :poll_ms,
    :deadline_ms,
    :started_at,
    :baseline,
    :max_fires,
    last_met: false,
    fires: 0,
    status: :running
  ]

  # ── Public API (called by the manager) ───────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Return a snapshot map: watch metadata + status + fire count."
  @spec snapshot(pid()) :: map()
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc "Stop a running watcher. Returns its final snapshot."
  @spec stop(pid()) :: map()
  def stop(pid), do: GenServer.call(pid, :stop)

  defp via(id), do: {:via, Registry, {@registry, id}}

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    input = Keyword.fetch!(opts, :input)
    id = Keyword.fetch!(opts, :id)

    mode =
      case Map.get(input, "mode", "once") do
        "repeat" -> :repeat
        _ -> :once
      end

    duration_s = Map.get(input, "duration_seconds", 60)
    poll_ms = Map.get(input, "poll_interval_ms", Constants.default_poll_interval_ms())

    max_fires =
      case Map.get(input, "max_fires") do
        n when is_integer(n) and n > 0 -> n
        _ -> if mode == :repeat, do: 100, else: 1
      end

    now = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      id: id,
      input: input,
      session_id: Keyword.get(opts, :session_id),
      kind: Map.get(input, "kind"),
      target: Map.get(input, "target"),
      mode: mode,
      condition: normalize_condition(Map.get(input, "condition")),
      poll_ms: poll_ms,
      deadline_ms: now + duration_s * 1_000,
      started_at: now,
      baseline: sample(input),
      max_fires: max_fires
    }

    emit(state, :monitor_started, %{mode: mode, poll_interval_ms: poll_ms})
    schedule_poll(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    now = System.monotonic_time(:millisecond)
    expired? = now >= state.deadline_ms

    # Sample BEFORE deciding to retire. `schedule_poll/1` clamps the last timer
    # to land exactly ON the deadline, so returning here on `expired?` without
    # sampling would leave the entire final poll window unobserved and report a
    # real change inside it as "no change". Observe first, conclude after: a
    # watch that was asked to cover N seconds actually covers all N.
    current = sample(state.input)
    {fired?, state} = evaluate(state, current)

    cond do
      fired? ->
        handle_fire(state, current, now, expired?)

      expired? ->
        emit(state, :monitor_timeout, %{elapsed_ms: now - state.started_at})
        {:stop, :normal, %{state | status: :timeout}}

      true ->
        schedule_poll(state)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, to_map(state), state}

  def handle_call(:stop, _from, state) do
    {:stop, :normal, to_map(%{state | status: :stopped}), %{state | status: :stopped}}
  end

  # ── Fire handling ─────────────────────────────────────────────────────

  defp handle_fire(state, current, now, expired?) do
    elapsed_ms = now - state.started_at
    fires = state.fires + 1

    emit(state, :monitor_fired, %{
      fire: fires,
      before: inspect(state.baseline),
      after: inspect(current),
      elapsed_ms: elapsed_ms
    })

    inject(state, current, elapsed_ms, fires)

    state = %{state | baseline: current, fires: fires}

    # `expired?` means this was the deadline sample: the change was reported,
    # and there is no window left to keep watching, so retire instead of
    # re-scheduling a zero-delay poll that could only time out.
    if state.mode == :once or fires >= state.max_fires or expired? do
      {:stop, :normal, %{state | status: :done}}
    else
      schedule_poll(state)
      {:noreply, state}
    end
  end

  # Change-detection (no condition) fires on any transition from the last
  # observed baseline. Condition mode edge-triggers: fires only on the rising
  # edge (not-met → met), so a steady condition (e.g. URL stays 200) fires once.
  defp evaluate(%{condition: nil} = state, current) do
    {current != state.baseline, state}
  end

  defp evaluate(state, current) do
    met = condition_met?(state.kind, current, state.condition)
    {met and not state.last_met, %{state | last_met: met}}
  end

  # ── Event emit + loop injection ──────────────────────────────────────

  defp emit(%{session_id: sid}, _event, _extra) when not is_binary(sid), do: :ok

  defp emit(state, event, extra) do
    Bus.emit(
      :system_event,
      Map.merge(
        %{
          event: event,
          session_id: state.session_id,
          watch_id: state.id,
          kind: state.kind,
          target: state.target
        },
        extra
      )
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp inject(%{session_id: sid}, _current, _elapsed_ms, _fires) when not is_binary(sid), do: :ok

  defp inject(state, current, elapsed_ms, fires) do
    fire_label = if state.mode == :repeat, do: " (occurrence #{fires})", else: ""

    body =
      "[monitor #{state.id}#{fire_label}: change on #{state.kind}:#{state.target} " <>
        "after #{format_duration(elapsed_ms)}]\n" <>
        "  before: #{inspect(state.baseline)}\n" <>
        "  after:  #{inspect(current)}"

    Loop.inject_agent_result(state.session_id, body)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp schedule_poll(state) do
    remaining = state.deadline_ms - System.monotonic_time(:millisecond)
    Process.send_after(self(), :poll, max(0, min(state.poll_ms, remaining)))
  end

  # ── Condition evaluation ──────────────────────────────────────────────

  defp normalize_condition(cond) when is_map(cond) and map_size(cond) > 0, do: cond
  defp normalize_condition(_), do: nil

  defp condition_met?("url", {:url, status}, cond) do
    case cond["status"] do
      n when is_integer(n) -> status == n
      _ -> false
    end
  end

  defp condition_met?("command", {:command, code, out}, cond) do
    exit_ok =
      case cond["exit"] do
        n when is_integer(n) -> code == n
        _ -> nil
      end

    contains_ok =
      case cond["contains"] do
        s when is_binary(s) -> String.contains?(out, s)
        _ -> nil
      end

    checks = Enum.reject([exit_ok, contains_ok], &is_nil/1)
    checks != [] and Enum.all?(checks)
  end

  defp condition_met?("process", {:process, alive}, cond) do
    case cond["alive"] do
      b when is_boolean(b) -> alive == b
      _ -> false
    end
  end

  defp condition_met?(_kind, _sample, _cond), do: false

  # ── Samplers (moved from the former blocking Handler.watch_loop) ──────

  defp sample(%{"kind" => "file", "target" => path}) do
    case File.stat(Path.expand(path)) do
      {:ok, %{mtime: m, size: s}} -> {:file, m, s}
      {:error, reason} -> {:file_error, reason}
    end
  end

  defp sample(%{"kind" => "process", "target" => target}) do
    pid = parse_pid(target)
    {:process, pid && Process.alive?(pid)}
  end

  defp sample(%{"kind" => "url", "target" => url}) do
    request = Finch.build(:get, url)

    case Finch.request(request, OptimalSystemAgent.Finch, receive_timeout: 5_000) do
      {:ok, %{status: status}} -> {:url, status}
      {:error, reason} -> {:url_error, inspect(reason)}
    end
  rescue
    e -> {:url_error, Exception.message(e)}
  end

  defp sample(%{"kind" => "command", "target" => cmd}) do
    case OptimalSystemAgent.OS.Shell.cmd(cmd, stderr_to_stdout: true) do
      {output, code} -> {:command, code, output |> String.trim_trailing() |> String.slice(0, 200)}
    end
  rescue
    e -> {:command_error, Exception.message(e)}
  end

  defp parse_pid(target) do
    pid_str = String.trim_leading(target, "#PID")

    try do
      :erlang.list_to_pid(String.to_charlist(pid_str))
    rescue
      _ -> nil
    end
  end

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_duration(ms) do
    s = div(ms, 1_000)
    "#{div(s, 60)}m#{rem(s, 60)}s"
  end

  defp to_map(state) do
    %{
      id: state.id,
      kind: state.kind,
      target: state.target,
      mode: state.mode,
      status: state.status,
      fires: state.fires,
      session_id: state.session_id,
      started_at: state.started_at
    }
  end
end
