defmodule CanopyWeb.SpawnController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.Session
  import Ecto.Query

  def create(conn, params) do
    agent_id = params["agent_id"]
    model = params["model"] || "claude-sonnet-4-20250514"
    context = params["context"] || ""

    session_params = %{
      agent_id: agent_id,
      model: model,
      status: "active",
      started_at: DateTime.utc_now()
    }

    changeset = Session.changeset(%Session{}, session_params)

    case Repo.insert(changeset) do
      {:ok, session} ->
        Canopy.EventBus.broadcast(
          Canopy.EventBus.agent_topic(agent_id),
          %{event: "run.started", session_id: session.id, context: context}
        )

        conn
        |> put_status(201)
        |> json(%{session: %{id: session.id, status: session.status}})

      {:error, cs} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: inspect(cs.errors)})
    end
  end

  def active(conn, _params) do
    sessions =
      Repo.all(
        from s in Session,
          where: s.status == "active",
          order_by: [desc: s.started_at]
      )

    json(conn, %{
      active:
        Enum.map(sessions, fn s ->
          %{id: s.id, agent_id: s.agent_id, model: s.model, started_at: s.started_at}
        end)
    })
  end

  def kill(conn, %{"id" => id}) do
    case Repo.get(Session, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      session ->
        {:ok, _} =
          session
          |> Ecto.Changeset.change(status: "cancelled", completed_at: DateTime.utc_now())
          |> Repo.update()

        json(conn, %{ok: true})
    end
  end

  def history(conn, params) do
    limit = min(String.to_integer(params["limit"] || "50"), 100)

    sessions =
      Repo.all(
        from s in Session,
          where: s.status in ["completed", "failed", "cancelled"],
          order_by: [desc: s.completed_at],
          limit: ^limit
      )

    json(conn, %{
      history:
        Enum.map(sessions, fn s ->
          %{
            id: s.id,
            agent_id: s.agent_id,
            model: s.model,
            status: s.status,
            started_at: s.started_at,
            completed_at: s.completed_at,
            cost_cents: s.cost_cents
          }
        end)
    })
  end
end
