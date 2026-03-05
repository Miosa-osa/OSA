defmodule OptimalSystemAgent.Telemetry.Metrics do
  @moduledoc """
  Telemetry GenServer for OSA runtime metrics.

  Subscribes to Events.Bus and tracks:
    - :tool_executions    — count by tool name (histogram)
    - :provider_latency   — avg/p99 latency by provider (last 100 calls)
    - :session_stats      — turns per session, messages per day
    - :noise_filter_rate  — % messages filtered by noise filter
    - :signal_weights     — distribution by bucket (0-0.2, 0.2-0.5, 0.5-0.8, 0.8-1.0)

  Writes a snapshot to ~/.osa/metrics.json every 5 minutes.

  ## Public API

      Metrics.record_tool_execution("search_files", 42)
      Metrics.record_provider_call(:anthropic, 1200, true)
      Metrics.record_noise_filter_result(:filtered)
      Metrics.record_signal_weight(0.73)
      Metrics.get_metrics()
      Metrics.get_summary()
  """

  use GenServer
  require Logger

  @flush_interval_ms 5 * 60 * 1_000
  @latency_window 100

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record a tool execution with its duration in milliseconds."
  def record_tool_execution(tool_name, duration_ms)
      when is_binary(tool_name) and is_number(duration_ms) do
    GenServer.cast(__MODULE__, {:tool_execution, tool_name, duration_ms})
  end

  @doc "Record an LLM provider call with latency and success flag."
  def record_provider_call(provider, latency_ms, success)
      when is_atom(provider) and is_number(latency_ms) and is_boolean(success) do
    GenServer.cast(__MODULE__, {:provider_call, provider, latency_ms, success})
  end

  @doc "Record the outcome of a noise filter check (:filtered | :clarify | :pass)."
  def record_noise_filter_result(outcome) when outcome in [:filtered, :clarify, :pass] do
    GenServer.cast(__MODULE__, {:noise_filter, outcome})
  end

  @doc "Record a signal weight value (0.0–1.0) for distribution tracking."
  def record_signal_weight(weight) when is_float(weight) or is_integer(weight) do
    GenServer.cast(__MODULE__, {:signal_weight, weight / 1})
  end

  @doc "Returns raw metrics map from ETS."
  def get_metrics do
    case :ets.whereis(:osa_telemetry) do
      :undefined -> %{}
      _ -> build_metrics()
    end
  end

  @doc "Returns a human-readable summary map."
  def get_summary do
    m = get_metrics()

    noise = m[:noise_filter] || %{filtered: 0, clarify: 0, pass: 0}
    total_noise = noise.filtered + noise.clarify + noise.pass
    filter_rate = if total_noise > 0, do: (noise.filtered + noise.clarify) / total_noise, else: 0.0

    %{
      tool_executions: summarize_tool_executions(Map.get(m, :tool_executions, %{})),
      provider_latency: summarize_latencies(Map.get(m, :provider_latency, %{})),
      session_stats: Map.get(m, :session_stats, %{turns_by_session: %{}, messages_today: 0}),
      noise_filter_rate: Float.round(filter_rate * 100, 2),
      signal_weight_distribution: Map.get(m, :signal_weights, empty_weight_buckets())
    }
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(:osa_telemetry, [:named_table, :public, :set])

    seed_table()
    subscribe_to_events()

    schedule_flush()
    Logger.info("[Telemetry.Metrics] Started — flushing to ~/.osa/metrics.json every 5m")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:tool_execution, tool_name, duration_ms}, state) do
    update_tool_execution(tool_name, duration_ms)
    {:noreply, state}
  end

  def handle_cast({:provider_call, provider, latency_ms, _success}, state) do
    update_provider_latency(provider, latency_ms)
    {:noreply, state}
  end

  def handle_cast({:noise_filter, outcome}, state) do
    update_noise_filter(outcome)
    {:noreply, state}
  end

  def handle_cast({:signal_weight, weight}, state) do
    update_signal_weight(weight)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_to_disk()
    schedule_flush()
    {:noreply, state}
  end

  # Handle events forwarded from Events.Bus subscriptions
  def handle_info({:osa_event, payload}, state) do
    handle_event(payload)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Event Bus Subscriptions ──────────────────────────────────────────

  defp subscribe_to_events do
    self_pid = self()

    OptimalSystemAgent.Events.Bus.register_handler(:tool_result, fn payload ->
      tool = Map.get(payload, :tool, Map.get(payload, "tool", "unknown"))
      duration = Map.get(payload, :duration_ms, Map.get(payload, "duration_ms", 0))
      send(self_pid, {:osa_event, {:tool_result, to_string(tool), duration}})
    end)

    OptimalSystemAgent.Events.Bus.register_handler(:llm_response, fn payload ->
      provider =
        payload
        |> Map.get(:provider, Map.get(payload, "provider", :unknown))
        |> to_atom_provider()

      latency = Map.get(payload, :latency_ms, Map.get(payload, "latency_ms", 0))
      success = Map.get(payload, :success, Map.get(payload, "success", true))
      send(self_pid, {:osa_event, {:llm_response, provider, latency, success}})
    end)

    OptimalSystemAgent.Events.Bus.register_handler(:user_message, fn payload ->
      session_id = Map.get(payload, :session_id, Map.get(payload, "session_id", "unknown"))
      send(self_pid, {:osa_event, {:user_message, to_string(session_id)}})
    end)
  end

  defp handle_event({:tool_result, tool_name, duration_ms}) do
    update_tool_execution(tool_name, duration_ms)
  end

  defp handle_event({:llm_response, provider, latency_ms, _success}) do
    update_provider_latency(provider, latency_ms)
  end

  defp handle_event({:user_message, session_id}) do
    update_session_stats(session_id)
  end

  defp handle_event(_other), do: :ok

  # ── ETS State Helpers ────────────────────────────────────────────────

  defp seed_table do
    :ets.insert(:osa_telemetry, {:tool_executions, %{}})
    :ets.insert(:osa_telemetry, {:provider_latency, %{}})
    :ets.insert(:osa_telemetry, {:session_stats, %{turns_by_session: %{}, messages_today: 0}})
    :ets.insert(:osa_telemetry, {:noise_filter, %{filtered: 0, clarify: 0, pass: 0}})
    :ets.insert(:osa_telemetry, {:signal_weights, empty_weight_buckets()})
  end

  # Tool execution stats: %{tool_name => %{count, total_ms, min_ms, max_ms, window}}
  # window is a circular buffer of the last 100 durations for p99 calculation.
  defp update_tool_execution(tool_name, duration_ms) do
    [{_, executions}] = :ets.lookup(:osa_telemetry, :tool_executions)

    updated =
      Map.update(
        executions,
        tool_name,
        %{count: 1, total_ms: duration_ms, min_ms: duration_ms, max_ms: duration_ms,
          window: [duration_ms]},
        fn stats ->
          new_window =
            [duration_ms | stats.window]
            |> Enum.take(@latency_window)

          %{stats |
            count: stats.count + 1,
            total_ms: stats.total_ms + duration_ms,
            min_ms: min(stats.min_ms, duration_ms),
            max_ms: max(stats.max_ms, duration_ms),
            window: new_window
          }
        end
      )

    :ets.insert(:osa_telemetry, {:tool_executions, updated})
  end

  defp update_provider_latency(provider, latency_ms) do
    [{_, latencies}] = :ets.lookup(:osa_telemetry, :provider_latency)

    window =
      latencies
      |> Map.get(provider, [])
      |> then(fn existing ->
        new = [latency_ms | existing]
        Enum.take(new, @latency_window)
      end)

    :ets.insert(:osa_telemetry, {:provider_latency, Map.put(latencies, provider, window)})
  end

  defp update_noise_filter(outcome) do
    [{_, counts}] = :ets.lookup(:osa_telemetry, :noise_filter)
    updated = Map.update(counts, outcome, 1, &(&1 + 1))
    :ets.insert(:osa_telemetry, {:noise_filter, updated})
  end

  defp update_signal_weight(weight) do
    [{_, buckets}] = :ets.lookup(:osa_telemetry, :signal_weights)

    key =
      cond do
        weight < 0.2 -> :"0.0-0.2"
        weight < 0.5 -> :"0.2-0.5"
        weight < 0.8 -> :"0.5-0.8"
        true -> :"0.8-1.0"
      end

    updated = Map.update(buckets, key, 1, &(&1 + 1))
    :ets.insert(:osa_telemetry, {:signal_weights, updated})
  end

  defp update_session_stats(session_id) do
    [{_, stats}] = :ets.lookup(:osa_telemetry, :session_stats)

    updated_turns = Map.update(stats.turns_by_session, session_id, 1, &(&1 + 1))

    updated = %{
      stats
      | turns_by_session: updated_turns,
        messages_today: stats.messages_today + 1
    }

    :ets.insert(:osa_telemetry, {:session_stats, updated})
  end

  # ── Aggregation Helpers ──────────────────────────────────────────────

  defp build_metrics do
    keys = [:tool_executions, :provider_latency, :session_stats, :noise_filter, :signal_weights]

    Enum.reduce(keys, %{}, fn key, acc ->
      case :ets.lookup(:osa_telemetry, key) do
        [{^key, value}] -> Map.put(acc, key, value)
        [] -> acc
      end
    end)
  end

  defp summarize_tool_executions(executions) do
    Map.new(executions, fn {tool_name, stats} ->
      {count, p99_ms, avg_ms} =
        if stats.count == 0 do
          {0, 0, 0.0}
        else
          sorted = Enum.sort(stats.window)
          window_count = length(sorted)
          p99_idx = max(0, round(window_count * 0.99) - 1)
          p99 = Enum.at(sorted, p99_idx, 0)
          avg = stats.total_ms / stats.count
          {stats.count, p99, Float.round(avg, 2)}
        end

      {tool_name, %{
        count: count,
        avg_ms: avg_ms,
        min_ms: stats.min_ms,
        max_ms: stats.max_ms,
        p99_ms: p99_ms
      }}
    end)
  end

  defp summarize_latencies(latencies_by_provider) do
    Map.new(latencies_by_provider, fn {provider, window} ->
      stats =
        if Enum.empty?(window) do
          %{avg_ms: 0, p99_ms: 0, count: 0}
        else
          sorted = Enum.sort(window)
          count = length(sorted)
          avg = Enum.sum(sorted) / count
          p99_idx = max(0, round(count * 0.99) - 1)
          p99 = Enum.at(sorted, p99_idx, 0)
          %{avg_ms: Float.round(avg, 2), p99_ms: p99, count: count}
        end

      {provider, stats}
    end)
  end

  defp empty_weight_buckets do
    %{
      "0.0-0.2": 0,
      "0.2-0.5": 0,
      "0.5-0.8": 0,
      "0.8-1.0": 0
    }
  end

  # ── Disk Persistence ─────────────────────────────────────────────────

  defp flush_to_disk do
    summary = get_summary()
    path = Path.expand("~/.osa/metrics.json")

    payload =
      summary
      |> Map.put(:flushed_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!(pretty: true)

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, payload) do
          :ok ->
            Logger.debug("[Telemetry.Metrics] Metrics written to #{path}")

          {:error, reason} ->
            Logger.warning("[Telemetry.Metrics] Failed to write metrics: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("[Telemetry.Metrics] Cannot create ~/.osa dir: #{inspect(reason)}")
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  # ── Utility ──────────────────────────────────────────────────────────

  defp to_atom_provider(provider) when is_atom(provider), do: provider

  defp to_atom_provider(provider) when is_binary(provider) do
    try do
      String.to_existing_atom(provider)
    rescue
      ArgumentError -> String.to_atom(provider)
    end
  end

  defp to_atom_provider(_), do: :unknown
end
