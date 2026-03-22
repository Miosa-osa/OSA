defmodule Canopy.Costs do
  @moduledoc "Cost tracking and budget management context."

  alias Canopy.Repo
  alias Canopy.Schemas.{CostEvent, BudgetPolicy, BudgetIncident, Agent}
  import Ecto.Query

  def cost_summary do
    today = Date.utc_today()
    bot = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")
    bow = DateTime.new!(Date.add(today, -(Date.day_of_week(today) - 1)), ~T[00:00:00], "Etc/UTC")
    bom = DateTime.new!(Date.new!(today.year, today.month, 1), ~T[00:00:00], "Etc/UTC")

    %{
      today_cents: cost_since(bot),
      week_cents: cost_since(bow),
      month_cents: cost_since(bom),
      top_agent: top_agent_this_month(bom)
    }
  end

  def cost_by_agent do
    Repo.all(
      from ce in CostEvent,
        join: a in Agent,
        on: ce.agent_id == a.id,
        group_by: [a.id, a.name, a.adapter],
        order_by: [desc: sum(ce.cost_cents)],
        select: %{
          agent_id: a.id,
          agent_name: a.name,
          adapter: a.adapter,
          total_cents: sum(ce.cost_cents),
          total_input: sum(ce.tokens_input),
          total_output: sum(ce.tokens_output),
          event_count: count(ce.id)
        }
    )
  end

  def cost_by_model do
    Repo.all(
      from ce in CostEvent,
        group_by: ce.model,
        order_by: [desc: sum(ce.cost_cents)],
        select: %{
          model: ce.model,
          total_cents: sum(ce.cost_cents),
          total_input: sum(ce.tokens_input),
          total_output: sum(ce.tokens_output),
          event_count: count(ce.id)
        }
    )
  end

  def daily_costs(days \\ 30) do
    since = DateTime.utc_now() |> DateTime.add(-days, :day)

    Repo.all(
      from ce in CostEvent,
        where: ce.inserted_at >= ^since,
        group_by: fragment("date_trunc('day', ?)", ce.inserted_at),
        order_by: fragment("date_trunc('day', ?)", ce.inserted_at),
        select: %{
          date: fragment("date_trunc('day', ?)", ce.inserted_at),
          total_cents: sum(ce.cost_cents),
          total_tokens: sum(ce.tokens_input) + sum(ce.tokens_output)
        }
    )
  end

  def list_cost_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Repo.all(
      from ce in CostEvent,
        join: a in Agent,
        on: ce.agent_id == a.id,
        order_by: [desc: ce.inserted_at],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: ce.id,
          agent_id: a.id,
          agent_name: a.name,
          model: ce.model,
          tokens_input: ce.tokens_input,
          tokens_output: ce.tokens_output,
          tokens_cache: ce.tokens_cache,
          cost_cents: ce.cost_cents,
          session_id: ce.session_id,
          inserted_at: ce.inserted_at
        }
    )
  end

  def list_budget_policies do
    Repo.all(from p in BudgetPolicy, order_by: [asc: p.scope_type, asc: p.scope_id])
  end

  def upsert_budget_policy(scope_type, scope_id, attrs) do
    case Repo.one(
           from p in BudgetPolicy,
             where: p.scope_type == ^scope_type and p.scope_id == ^scope_id
         ) do
      nil ->
        %BudgetPolicy{}
        |> BudgetPolicy.changeset(
          Map.merge(attrs, %{"scope_type" => scope_type, "scope_id" => scope_id})
        )
        |> Repo.insert()

      existing ->
        existing |> BudgetPolicy.changeset(attrs) |> Repo.update()
    end
  end

  def list_budget_incidents(opts \\ []) do
    query = from bi in BudgetIncident, order_by: [desc: bi.inserted_at], limit: 50

    query =
      case opts[:resolved] do
        true -> where(query, [bi], bi.resolved == true)
        false -> where(query, [bi], bi.resolved == false)
        _ -> query
      end

    Repo.all(query)
  end

  def resolve_incident(id) do
    case Repo.get(BudgetIncident, id) do
      nil ->
        {:error, :not_found}

      incident ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        incident |> Ecto.Changeset.change(resolved: true, resolved_at: now) |> Repo.update()
    end
  end

  defp cost_since(since) do
    Repo.one(
      from ce in CostEvent,
        where: ce.inserted_at >= ^since,
        select: coalesce(sum(ce.cost_cents), 0)
    ) || 0
  end

  defp top_agent_this_month(bom) do
    Repo.one(
      from ce in CostEvent,
        where: ce.inserted_at >= ^bom,
        join: a in Agent,
        on: ce.agent_id == a.id,
        group_by: [a.id, a.name],
        order_by: [desc: sum(ce.cost_cents)],
        limit: 1,
        select: %{
          agent_id: a.id,
          agent_name: a.name,
          cost_cents: sum(ce.cost_cents)
        }
    )
  end
end
