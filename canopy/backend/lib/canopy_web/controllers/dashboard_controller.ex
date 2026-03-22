defmodule CanopyWeb.DashboardController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.{Agent, Session, ActivityEvent}
  import Ecto.Query

  def show(conn, _params) do
    agents = Repo.all(from a in Agent, select: %{status: a.status, id: a.id})
    active_count = Enum.count(agents, &(&1.status in ["active", "working"]))
    total_count = length(agents)

    live_runs =
      Repo.all(
        from s in Session,
          where: s.status == "active",
          join: a in Agent,
          on: s.agent_id == a.id,
          select: %{
            id: s.id,
            agent_id: a.id,
            agent_name: a.name,
            model: s.model,
            started_at: s.started_at,
            tokens_input: s.tokens_input,
            tokens_output: s.tokens_output,
            cost_cents: s.cost_cents
          },
          limit: 20,
          order_by: [desc: s.started_at]
      )

    recent_activity =
      Repo.all(
        from e in ActivityEvent,
          order_by: [desc: e.inserted_at],
          limit: 20,
          select: %{
            id: e.id,
            event_type: e.event_type,
            message: e.message,
            level: e.level,
            agent_id: e.agent_id,
            inserted_at: e.inserted_at
          }
      )

    today = Date.utc_today()
    beginning_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    today_cost =
      Repo.one(
        from ce in Canopy.Schemas.CostEvent,
          where: ce.inserted_at >= ^beginning_of_day,
          select: coalesce(sum(ce.cost_cents), 0)
      ) || 0

    json(conn, %{
      kpis: %{
        active_agents: active_count,
        total_agents: total_count,
        live_runs: length(live_runs),
        today_cost_cents: today_cost
      },
      live_runs: live_runs,
      recent_activity: recent_activity,
      finance: %{
        today_cents: today_cost
      }
    })
  end
end
