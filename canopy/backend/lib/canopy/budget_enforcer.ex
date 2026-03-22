defmodule Canopy.BudgetEnforcer do
  @moduledoc """
  GenServer that enforces budget policies.

  Maintains an ETS table of accumulated costs per scope (agent/project/workspace).
  On each cost event, checks all applicable policies and enforces thresholds.

  The ETS table uses `:update_counter/4` for atomic increments — safe to call from
  concurrent processes without going through this GenServer.

  ## Usage

      Canopy.BudgetEnforcer.record_cost(%{
        agent_id: "...",
        session_id: "...",
        model: "claude-sonnet-4-6",
        tokens_input: 1500,
        tokens_output: 500,
        cost_cents: 3
      })
  """
  use GenServer
  require Logger

  alias Canopy.Repo
  alias Canopy.Schemas.{BudgetPolicy, BudgetIncident, CostEvent, Agent}
  import Ecto.Query

  @table :canopy_budget_accumulator

  # ── Client API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a cost event and check budget policies."
  def record_cost(params) do
    GenServer.cast(__MODULE__, {:record_cost, params})
  end

  @doc "Get current accumulated cost in cents for a scope."
  def get_accumulated(scope_type, scope_id) do
    case :ets.lookup(@table, {scope_type, scope_id}) do
      [{_, cents}] -> cents
      [] -> 0
    end
  end

  @doc "Reset accumulator for a scope (e.g. on month boundary or manual override)."
  def reset(scope_type, scope_id) do
    GenServer.cast(__MODULE__, {:reset, scope_type, scope_id})
  end

  # ── Server Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    load_current_month_costs()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:record_cost, params}, state) do
    cost = params.cost_cents
    agent_id = params.agent_id

    # 1. Persist cost event
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %CostEvent{}
    |> CostEvent.changeset(%{
      agent_id: agent_id,
      session_id: params[:session_id],
      model: params.model,
      tokens_input: params[:tokens_input] || 0,
      tokens_output: params[:tokens_output] || 0,
      tokens_cache: params[:tokens_cache] || 0,
      cost_cents: cost,
      inserted_at: now
    })
    |> Repo.insert!()

    # 2. Update ETS accumulators atomically
    increment("agent", agent_id, cost)

    case Repo.get(Agent, agent_id) do
      %Agent{workspace_id: ws_id} when not is_nil(ws_id) ->
        increment("workspace", ws_id, cost)

      _ ->
        :ok
    end

    # 3. Check policies for this agent scope
    check_policies("agent", agent_id)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:reset, scope_type, scope_id}, state) do
    :ets.insert(@table, {{scope_type, scope_id}, 0})
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # Atomic increment — safe for concurrent callers without a GenServer roundtrip.
  defp increment(scope_type, scope_id, cost_cents) do
    key = {scope_type, scope_id}
    # update_counter/4: create entry with default value 0 if missing, then add cost.
    :ets.update_counter(@table, key, {2, cost_cents}, {key, 0})
  end

  defp check_policies(scope_type, scope_id) do
    policies =
      Repo.all(
        from p in BudgetPolicy,
          where: p.scope_type == ^scope_type and p.scope_id == ^scope_id
      )

    for policy <- policies do
      accumulated = get_accumulated(scope_type, scope_id)

      pct =
        if policy.monthly_limit_cents > 0,
          do: div(accumulated * 100, policy.monthly_limit_cents),
          else: 0

      cond do
        pct >= 100 and policy.hard_stop ->
          handle_hard_stop(policy, scope_id, pct)

        pct >= policy.warning_threshold_pct ->
          handle_warning(policy, scope_id, pct)

        true ->
          :ok
      end
    end
  end

  defp handle_hard_stop(policy, agent_id, actual_pct) do
    existing =
      Repo.one(
        from bi in BudgetIncident,
          where:
            bi.policy_id == ^policy.id and bi.agent_id == ^agent_id and
              bi.incident_type == "hard_stop" and bi.resolved == false
      )

    unless existing do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %BudgetIncident{}
      |> BudgetIncident.changeset(%{
        policy_id: policy.id,
        agent_id: agent_id,
        incident_type: "hard_stop",
        threshold_pct: 100,
        actual_pct: actual_pct,
        inserted_at: now
      })
      |> Repo.insert!()

      case Repo.get(Agent, agent_id) do
        %Agent{} = agent ->
          agent
          |> Ecto.Changeset.change(status: "paused")
          |> Repo.update!()

          Logger.warning(
            "[BudgetEnforcer] Hard stop: agent #{agent.name} (#{agent_id}) reached #{actual_pct}% of budget"
          )

          Canopy.EventBus.broadcast(
            Canopy.EventBus.workspace_topic(agent.workspace_id),
            %{
              event: "budget.hard_stop",
              agent_id: agent_id,
              agent_name: agent.name,
              actual_pct: actual_pct,
              policy_id: policy.id
            }
          )

        nil ->
          :ok
      end
    end
  end

  defp handle_warning(policy, agent_id, actual_pct) do
    recent =
      Repo.one(
        from bi in BudgetIncident,
          where:
            bi.policy_id == ^policy.id and bi.agent_id == ^agent_id and
              bi.incident_type == "warning" and bi.resolved == false
      )

    unless recent do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %BudgetIncident{}
      |> BudgetIncident.changeset(%{
        policy_id: policy.id,
        agent_id: agent_id,
        incident_type: "warning",
        threshold_pct: policy.warning_threshold_pct,
        actual_pct: actual_pct,
        inserted_at: now
      })
      |> Repo.insert!()

      case Repo.get(Agent, agent_id) do
        %Agent{} = agent ->
          Logger.info(
            "[BudgetEnforcer] Warning: agent #{agent.name} (#{agent_id}) at #{actual_pct}% of budget"
          )

          Canopy.EventBus.broadcast(
            Canopy.EventBus.workspace_topic(agent.workspace_id),
            %{
              event: "budget.warning",
              agent_id: agent_id,
              agent_name: agent.name,
              actual_pct: actual_pct,
              threshold_pct: policy.warning_threshold_pct,
              policy_id: policy.id
            }
          )

        nil ->
          :ok
      end
    end
  end

  defp load_current_month_costs do
    today = Date.utc_today()
    month_start = DateTime.new!(Date.new!(today.year, today.month, 1), ~T[00:00:00], "Etc/UTC")

    Repo.all(
      from ce in CostEvent,
        where: ce.inserted_at >= ^month_start,
        group_by: ce.agent_id,
        select: {ce.agent_id, sum(ce.cost_cents)}
    )
    |> Enum.each(fn {agent_id, total} ->
      :ets.insert(@table, {{"agent", agent_id}, total})
    end)
  end
end
