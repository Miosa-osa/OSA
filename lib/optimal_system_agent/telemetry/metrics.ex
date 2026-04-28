defmodule OptimalSystemAgent.Telemetry.Metrics do
  @moduledoc """
  In-process metrics GenServer for OSA telemetry.

  Collects per-tool execution counts and durations, per-provider call
  latencies and success rates, and session statistics. All record_*
  calls are fire-and-forget casts — they never block callers.
  """
  use GenServer
  require Logger

  @name __MODULE__

  defstruct tools: %{}, providers: %{}, sessions: %{total_turns: 0}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, @name))
  end

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

  @doc "Get current metrics snapshot."
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
  def handle_call(:snapshot, _from, state) do
    # Compute p99 for each tool and provider
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

  defp percentile([], _p), do: 0

  defp percentile(durations, p) do
    sorted = Enum.sort(durations)
    idx = max(round(length(sorted) * p / 100) - 1, 0)
    Enum.at(sorted, idx, 0)
  end
end
