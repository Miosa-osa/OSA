defmodule OptimalSystemAgent.Agent.CostObservations do
  @moduledoc """
  Cost-aware routing feedback (#10). Records a rolling per-turn USD cost per
  `{provider, model}` and lets the router prefer the cheaper option for
  non-urgent (`:loose`) work — a "cheapest observed that still did the job"
  tie-break, never a capability/tier override.

  The average is an exponential moving average (EMA) so recent turns dominate
  without storing history. Storage is a public, self-owning named ETS table,
  the same lazily-started-unsupervised-owner pattern `Tools.FileState` uses: if
  the owner dies the table is recreated on next use and the worst case is a lost
  observation (falls back to no-data = today's routing), never a crash.
  """
  use GenServer
  require Logger

  @table :osa_cost_observations
  # EMA weight on the newest sample. 0.3 = ~last 5-6 turns dominate; enough to
  # track a model getting cheaper/pricier without thrashing on one outlier.
  @alpha 0.3

  # ── owner ──────────────────────────────────────────────────────────────
  @doc false
  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    ensure_ets()
    {:ok, %{}}
  end

  # ── API ────────────────────────────────────────────────────────────────

  @doc """
  Fold one turn's cost into the EMA for `{provider, model}`. Zero/nil cost and a
  missing provider/model are ignored (no basis to learn). Best-effort.
  """
  @spec record(term(), term(), number() | nil) :: :ok
  def record(provider, model, cost_usd)
      when not is_nil(provider) and not is_nil(model) and is_number(cost_usd) and cost_usd > 0 do
    ensure_table()
    key = {provider, to_string(model)}

    next =
      case safe_lookup(key) do
        [{^key, prev}] when is_number(prev) -> prev + @alpha * (cost_usd - prev)
        _ -> cost_usd
      end

    safe_insert(key, next)
    :ok
  end

  def record(_, _, _), do: :ok

  @doc "Observed EMA cost for `{provider, model}`, or `nil` when never seen."
  @spec avg_cost(term(), term()) :: float() | nil
  def avg_cost(provider, model) do
    ensure_table()

    case safe_lookup({provider, to_string(model)}) do
      [{_key, v}] when is_number(v) -> v * 1.0
      _ -> nil
    end
  end

  @doc "Drop all observations. Test/maintenance helper."
  @spec reset() :: :ok
  def reset do
    ensure_table()

    try do
      :ets.delete_all_objects(@table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc false
  # Telemetry handler for `[:osa, :accounting, :provider_cost]`. Attached in
  # Application.start/2. Prefers the provider's authoritative cost, falling back
  # to the rate-card estimate. Never raises into the telemetry dispatcher.
  def handle_telemetry(_event, measurements, metadata, _config) do
    cost =
      case Map.get(measurements, :provider_cost_usd) do
        c when is_number(c) and c > 0 -> c
        _ -> Map.get(measurements, :rate_card_estimate_usd)
      end

    record(Map.get(metadata, :provider), Map.get(metadata, :model), cost)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── ETS plumbing (mirrors Tools.FileState) ───────────────────────────────
  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp safe_insert(key, val) do
    :ets.insert(@table, {key, val})
    :ok
  rescue
    ArgumentError ->
      ensure_table()

      try do
        :ets.insert(@table, {key, val})
      rescue
        ArgumentError -> :ok
      end

      :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          _ -> ensure_ets()
        end

      _ ->
        :ok
    end
  end

  defp ensure_ets do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end
end
