defmodule OptimalSystemAgent.Telemetry.Metrics do
  @moduledoc """
  In-process metrics GenServer for OSA telemetry.

  Collects per-tool execution counts and durations, per-provider call
  latencies and success rates, session statistics, noise-filter outcomes,
  and signal-weight distributions. All record_* calls are fire-and-forget
  casts — they never block callers.
  """
  use GenServer
  require Logger

  @name __MODULE__

  @signal_buckets [:"0.0-0.2", :"0.2-0.5", :"0.5-0.8", :"0.8-1.0"]

  defstruct tools: %{},
            providers: %{},
            sessions: %{total_turns: 0, turns_by_session: %{}, messages_today: 0},
            noise_filter: %{filtered: 0, clarify: 0, pass: 0},
            signal_weights: %{
              "0.0-0.2": 0,
              "0.2-0.5": 0,
              "0.5-0.8": 0,
              "0.8-1.0": 0
            }

  # ── Client API (new — matches test expectations) ──────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, @name))
  end

  @doc "Record a tool execution with duration in ms (alias for record_tool/2)."
  def record_tool_execution(tool_name, duration_ms) do
    GenServer.cast(@name, {:record_tool, tool_name, duration_ms, true})
  rescue
    _ -> :ok
  end

  @doc "Record an LLM provider call with duration in ms and success flag."
  def record_provider_call(provider, duration_ms, success) do
    GenServer.cast(@name, {:record_provider, provider, duration_ms, success})
  rescue
    _ -> :ok
  end

  @doc "Record a noise-filter outcome (:filtered | :clarify | :pass)."
  def record_noise_filter_result(outcome) when outcome in [:filtered, :clarify, :pass] do
    GenServer.cast(@name, {:record_noise_filter, outcome})
  rescue
    _ -> :ok
  end

  @doc "Record a signal weight value (0.0–1.0) into the appropriate histogram bucket."
  def record_signal_weight(weight) when is_number(weight) do
    GenServer.cast(@name, {:record_signal_weight, weight})
  rescue
    _ -> :ok
  end

  @doc "Get raw metrics snapshot with the richer schema expected by tests."
  def get_metrics do
    GenServer.call(@name, :get_metrics)
  rescue
    _ ->
      %{
        tool_executions: %{},
        provider_latency: %{},
        session_stats: %{turns_by_session: %{}, messages_today: 0},
        noise_filter: %{filtered: 0, clarify: 0, pass: 0},
        signal_weights: Enum.into(@signal_buckets, %{}, &{&1, 0})
      }
  end

  @doc "Get computed summary (p99, averages, filter rate, bucket distributions)."
  def get_summary do
    GenServer.call(@name, :get_summary)
  rescue
    _ ->
      %{
        tool_executions: %{},
        provider_latency: %{},
        session_stats: %{turns_by_session: %{}, messages_today: 0},
        noise_filter_rate: 0.0,
        signal_weight_distribution: Enum.into(@signal_buckets, %{}, &{&1, 0})
      }
  end

  # ── Client API (legacy — kept for existing callers) ───────────────────

  @doc "Record a tool execution with duration in ms."
  def record_tool(tool_name, duration_ms, success \\ true) do
    GenServer.cast(@name, {:record_tool, tool_name, duration_ms, success})
  rescue
    _ -> :ok
  end

  @doc "Record an LLM provider call with duration in ms."
  def record_provider(provider, duration_ms, success \\ true) do
    GenServer.cast(@name, {:record_provider, provider, duration_ms, success})
  rescue
    _ -> :ok
  end

  @doc "Record a session turn."
  def record_turn do
    GenServer.cast(@name, :record_turn)
  rescue
    _ -> :ok
  end

  @doc "Get current metrics snapshot (legacy format)."
  def snapshot do
    GenServer.call(@name, :snapshot)
  rescue
    _ -> %{tools: %{}, providers: %{}, sessions: %{total_turns: 0}}
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:record_tool, name, duration_ms, success}, state) do
    entry =
      Map.get(state.tools, name, %{
        count: 0,
        success: 0,
        fail: 0,
        total_ms: 0,
        min_ms: nil,
        max_ms: 0,
        durations: []
      })

    durations = Enum.take([duration_ms | entry.durations], 100)
    min_ms = if entry.min_ms, do: min(entry.min_ms, duration_ms), else: duration_ms

    updated = %{
      entry
      | count: entry.count + 1,
        success: entry.success + if(success, do: 1, else: 0),
        fail: entry.fail + if(success, do: 0, else: 1),
        total_ms: entry.total_ms + duration_ms,
        min_ms: min_ms,
        max_ms: max(entry.max_ms, duration_ms),
        durations: durations
    }

    {:noreply, %{state | tools: Map.put(state.tools, name, updated)}}
  end

  @impl true
  def handle_cast({:record_provider, provider, duration_ms, success}, state) do
    entry =
      Map.get(state.providers, provider, %{
        count: 0,
        success: 0,
        fail: 0,
        total_ms: 0,
        min_ms: nil,
        max_ms: 0,
        durations: []
      })

    durations = Enum.take([duration_ms | entry.durations], 100)
    min_ms = if entry.min_ms, do: min(entry.min_ms, duration_ms), else: duration_ms

    updated = %{
      entry
      | count: entry.count + 1,
        success: entry.success + if(success, do: 1, else: 0),
        fail: entry.fail + if(success, do: 0, else: 1),
        total_ms: entry.total_ms + duration_ms,
        min_ms: min_ms,
        max_ms: max(entry.max_ms, duration_ms),
        durations: durations
    }

    {:noreply, %{state | providers: Map.put(state.providers, provider, updated)}}
  end

  @impl true
  def handle_cast(:record_turn, state) do
    sessions = %{state.sessions | total_turns: state.sessions.total_turns + 1}
    {:noreply, %{state | sessions: sessions}}
  end

  @impl true
  def handle_cast({:record_noise_filter, outcome}, state) do
    noise = Map.update!(state.noise_filter, outcome, &(&1 + 1))
    {:noreply, %{state | noise_filter: noise}}
  end

  @impl true
  def handle_cast({:record_signal_weight, weight}, state) do
    bucket = signal_bucket(weight)
    weights = Map.update!(state.signal_weights, bucket, &(&1 + 1))
    {:noreply, %{state | signal_weights: weights}}
  end

  # ── Snapshot handlers ─────────────────────────────────────────────────

  @impl true
  def handle_call(:snapshot, _from, state) do
    tools_with_p99 =
      Enum.map(state.tools, fn {name, entry} ->
        p99 = percentile(entry.durations, 99)
        avg = if entry.count > 0, do: round(entry.total_ms / entry.count), else: 0
        {name, Map.merge(entry, %{p99_ms: p99, avg_ms: avg}) |> Map.delete(:durations)}
      end)
      |> Map.new()

    providers_with_p99 =
      Enum.map(state.providers, fn {name, entry} ->
        p99 = percentile(entry.durations, 99)
        avg = if entry.count > 0, do: round(entry.total_ms / entry.count), else: 0
        {name, Map.merge(entry, %{p99_ms: p99, avg_ms: avg}) |> Map.delete(:durations)}
      end)
      |> Map.new()

    {:reply, %{tools: tools_with_p99, providers: providers_with_p99, sessions: state.sessions},
     state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = %{
      tool_executions: state.tools |> strip_durations(),
      provider_latency: state.providers |> strip_durations(),
      session_stats: state.sessions,
      noise_filter: state.noise_filter,
      signal_weights: state.signal_weights
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    tool_executions =
      Enum.map(state.tools, fn {name, entry} ->
        p99 = percentile(entry.durations, 99)
        avg = if entry.count > 0, do: entry.total_ms / entry.count, else: 0.0

        stats = %{
          count: entry.count,
          avg_ms: avg,
          min_ms: entry.min_ms || 0,
          max_ms: entry.max_ms,
          p99_ms: p99
        }

        {name, stats}
      end)
      |> Map.new()

    provider_latency =
      Enum.map(state.providers, fn {name, entry} ->
        p99 = percentile(entry.durations, 99)
        avg = if entry.count > 0, do: entry.total_ms / entry.count, else: 0.0

        stats = %{
          count: entry.count,
          avg_ms: avg,
          p99_ms: p99
        }

        {name, stats}
      end)
      |> Map.new()

    noise_filter_rate = compute_filter_rate(state.noise_filter)

    summary = %{
      tool_executions: tool_executions,
      provider_latency: provider_latency,
      session_stats: state.sessions,
      noise_filter_rate: noise_filter_rate,
      signal_weight_distribution: state.signal_weights
    }

    {:reply, summary, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────

  defp percentile([], _p), do: 0

  defp percentile(durations, p) do
    sorted = Enum.sort(durations)
    idx = max(round(length(sorted) * p / 100) - 1, 0)
    Enum.at(sorted, idx, 0)
  end

  defp strip_durations(map) do
    Enum.map(map, fn {k, v} -> {k, Map.delete(v, :durations)} end) |> Map.new()
  end

  defp compute_filter_rate(%{filtered: f, clarify: c, pass: p}) do
    total = f + c + p

    if total == 0 do
      0.0
    else
      f / total * 100.0
    end
  end

  defp signal_bucket(w) when w < 0.2, do: :"0.0-0.2"
  defp signal_bucket(w) when w < 0.5, do: :"0.2-0.5"
  defp signal_bucket(w) when w < 0.8, do: :"0.5-0.8"
  defp signal_bucket(_), do: :"0.8-1.0"
end
