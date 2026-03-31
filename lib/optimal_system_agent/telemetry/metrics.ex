defmodule OptimalSystemAgent.Telemetry.Metrics do
  @moduledoc """
  In-process metrics GenServer for OSA telemetry.

  Collects:
  - Tool execution counts and durations (per tool name)
  - LLM provider call latencies and success rates (per provider)
  - Noise filter outcomes (:filtered / :clarify / :pass)
  - Signal weight distribution (bucketed into 4 ranges)
  - Session statistics (turns per session, messages today)

  All record_* calls are fire-and-forget casts — they never block callers.
  """

  use GenServer

  @name __MODULE__

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, @name))
  end

  @doc "Record a tool execution with its duration in milliseconds."
  @spec record_tool_execution(String.t(), number()) :: :ok
  def record_tool_execution(tool_name, duration_ms) when is_binary(tool_name) do
    GenServer.cast(@name, {:record_tool, tool_name, duration_ms})
  end

  @doc "Record an LLM provider call with latency and success flag."
  @spec record_provider_call(atom(), number(), boolean()) :: :ok
  def record_provider_call(provider, latency_ms, success?) when is_atom(provider) do
    GenServer.cast(@name, {:record_provider, provider, latency_ms, success?})
  end

  @doc "Record a noise filter outcome (:filtered | :clarify | :pass)."
  @spec record_noise_filter_result(:filtered | :clarify | :pass) :: :ok
  def record_noise_filter_result(outcome) when outcome in [:filtered, :clarify, :pass] do
    GenServer.cast(@name, {:record_noise, outcome})
  end

  @doc "Record a signal weight value (0.0–1.0)."
  @spec record_signal_weight(number()) :: :ok
  def record_signal_weight(weight) when is_number(weight) do
    GenServer.cast(@name, {:record_signal_weight, weight})
  end

  @doc "Return raw metrics map."
  @spec get_metrics() :: map()
  def get_metrics do
    GenServer.call(@name, :get_metrics)
  end

  @doc "Return a human-readable summary map with derived stats."
  @spec get_summary() :: map()
  def get_summary do
    GenServer.call(@name, :get_summary)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @initial_state %{
    tool_executions: %{},
    provider_latency: %{},
    noise_filter: %{filtered: 0, clarify: 0, pass: 0},
    signal_weights: %{
      "0.0-0.2": 0,
      "0.2-0.5": 0,
      "0.5-0.8": 0,
      "0.8-1.0": 0
    },
    session_stats: %{
      turns_by_session: %{},
      messages_today: 0
    }
  }

  @impl GenServer
  def init(:ok), do: {:ok, @initial_state}

  @impl GenServer
  def handle_cast({:record_tool, tool, duration_ms}, state) do
    entry = Map.get(state.tool_executions, tool, %{count: 0, total_ms: 0, samples: []})
    updated = %{entry |
      count: entry.count + 1,
      total_ms: entry.total_ms + duration_ms,
      samples: [duration_ms | entry.samples]
    }
    {:noreply, put_in(state, [:tool_executions, tool], updated)}
  end

  def handle_cast({:record_provider, provider, latency_ms, success?}, state) do
    entry = Map.get(state.provider_latency, provider, %{count: 0, total_ms: 0, success: 0, error: 0, samples: []})
    updated = %{entry |
      count: entry.count + 1,
      total_ms: entry.total_ms + latency_ms,
      success: entry.success + if(success?, do: 1, else: 0),
      error: entry.error + if(success?, do: 0, else: 1),
      samples: [latency_ms | entry.samples]
    }
    {:noreply, put_in(state, [:provider_latency, provider], updated)}
  end

  def handle_cast({:record_noise, outcome}, state) do
    {:noreply, update_in(state, [:noise_filter, outcome], &(&1 + 1))}
  end

  def handle_cast({:record_signal_weight, weight}, state) do
    bucket = weight_bucket(weight)
    {:noreply, update_in(state, [:signal_weights, bucket], &(&1 + 1))}
  end

  @impl GenServer
  def handle_call(:get_metrics, _from, state), do: {:reply, state, state}

  def handle_call(:get_summary, _from, state) do
    noise = state.noise_filter
    total_noise = noise.filtered + noise.clarify + noise.pass

    noise_filter_rate =
      if total_noise == 0 do
        0.0
      else
        Float.round(noise.filtered / total_noise * 100.0, 2)
      end

    tool_summary =
      Map.new(state.tool_executions, fn {name, %{count: c, total_ms: t, samples: samples}} ->
        avg = if c > 0, do: Float.round(t / c, 2), else: 0.0
        sorted = Enum.sort(samples)
        min_ms = List.first(sorted) || 0
        max_ms = List.last(sorted) || 0
        p99_ms = percentile(sorted, 99)
        {name, %{count: c, avg_ms: avg, total_ms: t, min_ms: min_ms, max_ms: max_ms, p99_ms: p99_ms}}
      end)

    provider_summary =
      Map.new(state.provider_latency, fn {name, %{count: c, total_ms: t, samples: samples} = e} ->
        avg = if c > 0, do: Float.round(t / c, 2), else: 0.0
        sorted = Enum.sort(samples)
        p99_ms = percentile(sorted, 99)
        {name, %{count: c, avg_ms: avg, p99_ms: p99_ms, success: e.success, error: e.error}}
      end)

    summary = %{
      tool_executions: tool_summary,
      provider_latency: provider_summary,
      session_stats: state.session_stats,
      noise_filter_rate: noise_filter_rate,
      signal_weight_distribution: state.signal_weights
    }

    {:reply, summary, state}
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp weight_bucket(w) when w < 0.2, do: :"0.0-0.2"
  defp weight_bucket(w) when w < 0.5, do: :"0.2-0.5"
  defp weight_bucket(w) when w < 0.8, do: :"0.5-0.8"
  defp weight_bucket(_), do: :"0.8-1.0"

  # Returns the Nth percentile from a pre-sorted list of numbers.
  # Returns 0 for empty lists.
  defp percentile([], _n), do: 0
  defp percentile(sorted, n) do
    count = length(sorted)
    idx = round(count * n / 100) - 1
    idx = max(idx, 0)
    Enum.at(sorted, min(idx, count - 1))
  end
end
