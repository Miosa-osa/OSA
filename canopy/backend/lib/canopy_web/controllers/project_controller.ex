defmodule CanopyWeb.ProjectController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.{Project, Goal}
  import Ecto.Query

  def index(conn, params) do
    workspace_id = params["workspace_id"]

    query = from p in Project, order_by: [desc: p.updated_at]

    query =
      if workspace_id,
        do: where(query, [p], p.workspace_id == ^workspace_id),
        else: query

    projects = Repo.all(query)
    json(conn, %{projects: Enum.map(projects, &serialize/1)})
  end

  def create(conn, params) do
    changeset = Project.changeset(%Project{}, params)

    case Repo.insert(changeset) do
      {:ok, project} ->
        conn |> put_status(201) |> json(%{project: serialize(project)})

      {:error, cs} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(cs)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Project, id) |> Repo.preload(:goals) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      project ->
        goal_count = length(project.goals)

        json(conn, %{
          project:
            serialize(project)
            |> Map.put(:goal_count, goal_count)
        })
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Repo.get(Project, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      project ->
        changeset = Project.changeset(project, params)

        case Repo.update(changeset) do
          {:ok, updated} ->
            json(conn, %{project: serialize(updated)})

          {:error, cs} ->
            conn
            |> put_status(422)
            |> json(%{error: "validation_failed", details: format_errors(cs)})
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(Project, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      project ->
        Repo.delete!(project)
        json(conn, %{ok: true})
    end
  end

  def goals(conn, %{"project_id" => project_id}) do
    goals =
      Repo.all(
        from g in Goal,
          where: g.project_id == ^project_id,
          order_by: [asc: g.title]
      )

    json(conn, %{goals: Enum.map(goals, &serialize_goal/1)})
  end

  def workspaces(conn, %{"project_id" => _project_id}) do
    # Projects are workspace-scoped; the parent workspace is accessible via the project record
    json(conn, %{workspaces: []})
  end

  # --- Private helpers ---

  defp serialize(%Project{} = p) do
    %{
      id: p.id,
      name: p.name,
      description: p.description,
      status: p.status,
      workspace_id: p.workspace_id,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp serialize_goal(%Goal{} = g) do
    %{
      id: g.id,
      title: g.title,
      description: g.description,
      status: g.status,
      project_id: g.project_id,
      parent_id: g.parent_id,
      inserted_at: g.inserted_at,
      updated_at: g.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
