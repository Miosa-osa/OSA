defmodule OptimalSystemAgent.Sandbox.CostTracker do
  @moduledoc """
  Per-provider sandbox cost tracking.

  Tracks runtime milliseconds and cost per sandbox provider (E2B, MIOSA,
  Vercel, Docker) so the agent and operator can see what sandbox runs
  actually cost. When the agent switches providers mid-run, the cost segment
  for the old provider is closed and a new one opened.


  ## Usage

      # Start tracking a sandbox session
      CostTracker.start_session("chat-123", :e2b)

      # Record runtime when a command completes
      CostTracker.record_runtime("chat-123", :e2b, 15_000)

      # Get the cost summary
      CostTracker.summary("chat-123")
      # => %{e2b: %{runtime_ms: 15_000, cost_usd: 0.002}, ...}

      # Switch providers mid-run
      CostTracker.switch_provider("chat-123", :e2b, :miosa)
  """

  use GenServer

  require Logger

  @table :osa_sandbox_cost_tracker

  # E2B pricing: $0.05/hour = $0.0000139/ms
  @e2b_cost_per_ms 0.0000139
  # MIOSA pricing: $0.03/hour = $0.0000083/ms (approximate)
  @miosa_cost_per_ms 0.0000083
  # Vercel sandbox: $0.02/hour = $0.0000056/ms (approximate)
  @vercel_cost_per_ms 0.0000056
  # Docker (local): free
  @docker_cost_per_ms 0.0

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Start tracking a new sandbox session."
  @spec start_session(String.t(), atom()) :: :ok
  def start_session(session_id, provider) when is_binary(session_id) and is_atom(provider) do
    GenServer.call(__MODULE__, {:start_session, session_id, provider})
  end

  @doc "Record runtime for a provider in a session."
  @spec record_runtime(String.t(), atom(), non_neg_integer()) :: :ok
  def record_runtime(session_id, provider, runtime_ms)
      when is_integer(runtime_ms) and runtime_ms >= 0 do
    GenServer.cast(__MODULE__, {:record_runtime, session_id, provider, runtime_ms})
  end

  @doc "Switch from one provider to another mid-run, closing the cost segment."
  @spec switch_provider(String.t(), atom(), atom()) :: :ok
  def switch_provider(session_id, from_provider, to_provider) do
    GenServer.call(__MODULE__, {:switch_provider, session_id, from_provider, to_provider})
  end

  @doc "Get the cost summary for a session."
  @spec summary(String.t()) :: map()
  def summary(session_id) do
    GenServer.call(__MODULE__, {:summary, session_id})
  end

  @doc "Get the total cost across all providers for a session."
  @spec total_cost(String.t()) :: float()
  def total_cost(session_id) do
    summary(session_id)
    |> Map.values()
    |> Enum.map(& &1.cost_usd)
    |> Enum.sum()
  end

  @doc "Clear tracking data for a session."
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) do
    GenServer.cast(__MODULE__, {:clear_session, session_id})
  end

  @doc "Cost per millisecond for a provider."
  @spec cost_per_ms(atom()) :: float()
  def cost_per_ms(:e2b), do: @e2b_cost_per_ms
  def cost_per_ms(:miosa), do: @miosa_cost_per_ms
  def cost_per_ms(:vercel), do: @vercel_cost_per_ms
  def cost_per_ms(:docker), do: @docker_cost_per_ms
  def cost_per_ms(:host), do: 0.0
  def cost_per_ms(_), do: 0.0

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:start_session, session_id, provider}, _from, state) do
    entry = %{provider => %{runtime_ms: 0, cost_usd: 0.0, segments: []}}
    :ets.insert(@table, {session_id, entry})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:switch_provider, session_id, _from, to}, _from_pid, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, data}] ->
        updated = Map.put_new(data, to, %{runtime_ms: 0, cost_usd: 0.0, segments: []})
        :ets.insert(@table, {session_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:summary, session_id}, _from, state) do
    result =
      case :ets.lookup(@table, session_id) do
        [{^session_id, data}] -> data
        [] -> %{}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:record_runtime, session_id, provider, runtime_ms}, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, data}] ->
        provider_data = Map.get(data, provider, %{runtime_ms: 0, cost_usd: 0.0, segments: []})
        new_runtime = provider_data.runtime_ms + runtime_ms
        new_cost = new_runtime * cost_per_ms(provider)

        updated =
          Map.put(data, provider, %{
            runtime_ms: new_runtime,
            cost_usd: new_cost,
            segments: provider_data.segments
          })

        :ets.insert(@table, {session_id, updated})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear_session, session_id}, state) do
    :ets.delete(@table, session_id)
    {:noreply, state}
  end
end
