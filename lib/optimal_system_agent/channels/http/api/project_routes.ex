defmodule OptimalSystemAgent.Channels.HTTP.API.ProjectRoutes do
  @moduledoc """
  Project and goal management routes for the OSA HTTP API.

  Storage: ~/.osa/projects.json (JSON file, no database).

  Forwarded prefix: /projects

  Effective routes:
    GET    /projects              → List all projects
    POST   /projects              → Create a project
    GET    /projects/:id          → Get a project by ID
    PUT    /projects/:id          → Update a project
    DELETE /projects/:id          → Archive a project (soft delete)
    GET    /projects/:id/goals    → Get goal tree for a project
    POST   /projects/:id/goals    → Create a goal on a project
    PUT    /projects/:id/goals/:goal_id   → Update a goal
    DELETE /projects/:id/goals/:goal_id  → Remove a goal
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — list all projects ──────────────────────────────────────────────

  get "/" do
    projects = read_projects()
    json(conn, 200, %{projects: projects, count: length(projects)})
  end

  # ── POST / — create a project ──────────────────────────────────────────────

  post "/" do
    params = conn.body_params

    case params do
      %{"name" => name} when is_binary(name) and name != "" ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        project = %{
          "id" => generate_id("proj_"),
          "name" => name,
          "description" => Map.get(params, "description", ""),
          "status" => "active",
          "workspace_id" => Map.get(params, "workspace_id"),
          "goals" => [],
          "created_at" => now,
          "updated_at" => now
        }

        try do
          projects = read_projects()
          write_projects([project | projects])
          json(conn, 201, project)
        rescue
          e ->
            Logger.warning("[ProjectRoutes] Failed to create project: #{Exception.message(e)}")
            json_error(conn, 500, "internal_error", "Failed to persist project")
        end

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: name")
    end
  end

  # ── GET /:id — get a project ───────────────────────────────────────────────

  get "/:id" do
    id = conn.params["id"]
    projects = read_projects()

    case find_project(projects, id) do
      nil -> json_error(conn, 404, "not_found", "Project not found")
      project -> json(conn, 200, project)
    end
  end

  # ── PUT /:id — update a project ───────────────────────────────────────────

  put "/:id" do
    id = conn.params["id"]
    params = conn.body_params
    projects = read_projects()

    case find_project(projects, id) do
      nil ->
        json_error(conn, 404, "not_found", "Project not found")

      project ->
        allowed = ~w(name description status)
        updates = Map.take(params, allowed)

        updated =
          project
          |> Map.merge(updates)
          |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

        new_projects = Enum.map(projects, fn p -> if p["id"] == id, do: updated, else: p end)

        try do
          write_projects(new_projects)
          json(conn, 200, updated)
        rescue
          e ->
            Logger.warning(
              "[ProjectRoutes] Failed to update project #{id}: #{Exception.message(e)}"
            )

            json_error(conn, 500, "internal_error", "Failed to persist project update")
        end
    end
  end

  # ── DELETE /:id — archive a project (soft delete) ─────────────────────────

  delete "/:id" do
    id = conn.params["id"]
    projects = read_projects()

    case find_project(projects, id) do
      nil ->
        json_error(conn, 404, "not_found", "Project not found")

      project ->
        archived =
          project
          |> Map.put("status", "archived")
          |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

        new_projects = Enum.map(projects, fn p -> if p["id"] == id, do: archived, else: p end)

        try do
          write_projects(new_projects)
          json(conn, 200, archived)
        rescue
          e ->
            Logger.warning(
              "[ProjectRoutes] Failed to archive project #{id}: #{Exception.message(e)}"
            )

            json_error(conn, 500, "internal_error", "Failed to persist project archive")
        end
    end
  end

  # ── GET /:id/goals — list goals for a project ─────────────────────────────

  get "/:id/goals" do
    id = conn.params["id"]
    projects = read_projects()

    case find_project(projects, id) do
      nil ->
        json_error(conn, 404, "not_found", "Project not found")

      project ->
        goals = Map.get(project, "goals", [])
        json(conn, 200, %{goals: goals, count: length(goals)})
    end
  end

  # ── POST /:id/goals — create a goal on a project ──────────────────────────

  post "/:id/goals" do
    id = conn.params["id"]
    params = conn.body_params
    projects = read_projects()

    case find_project(projects, id) do
      nil ->
        json_error(conn, 404, "not_found", "Project not found")

      project ->
        case params do
          %{"text" => text} when is_binary(text) and text != "" ->
            now = DateTime.utc_now() |> DateTime.to_iso8601()

            goal = %{
              "id" => generate_id("goal_"),
              "text" => text,
              "status" => "pending",
              "parent_id" => Map.get(params, "parent_id"),
              "children" => [],
              "created_at" => now
            }

            existing_goals = Map.get(project, "goals", [])

            updated_project =
              project
              |> Map.put("goals", existing_goals ++ [goal])
              |> Map.put("updated_at", now)

            new_projects =
              Enum.map(projects, fn p -> if p["id"] == id, do: updated_project, else: p end)

            try do
              write_projects(new_projects)
              json(conn, 201, goal)
            rescue
              e ->
                Logger.warning(
                  "[ProjectRoutes] Failed to create goal on project #{id}: #{Exception.message(e)}"
                )

                json_error(conn, 500, "internal_error", "Failed to persist goal")
            end

          _ ->
            json_error(conn, 400, "invalid_request", "Missing required field: text")
        end
    end
  end

  # ── PUT /:id/goals/:goal_id — update a goal ───────────────────────────────

  put "/:id/goals/:goal_id" do
    id = conn.params["id"]
    goal_id = conn.params["goal_id"]
    params = conn.body_params
    projects = read_projects()

    case find_project(projects, id) do
      nil ->
        json_error(conn, 404, "not_found", "Project not found")

      project ->
        goals = Map.get(project, "goals", [])
        goal = Enum.find(goals, fn g -> g["id"] == goal_id end)

        case goal do
          nil ->
            json_error(conn, 404, "not_found", "Goal not found")

          existing ->
            allowed = ~w(text status)
            updates = Map.take(params, allowed)
            updated_goal = Map.merge(existing, updates)

            new_goals =
              Enum.map(goals, fn g -> if g["id"] == goal_id, do: updated_goal, else: g end)

            updated_project =
              project
              |> Map.put("goals", new_goals)
              |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

            new_projects =
              Enum.map(projects, fn p -> if p["id"] == id, do: updated_project, else: p end)

            try do
              write_projects(new_projects)
              json(conn, 200, updated_goal)
            rescue
              e ->
                Logger.warning(
                  "[ProjectRoutes] Failed to update goal #{goal_id}: #{Exception.message(e)}"
                )

                json_error(conn, 500, "internal_error", "Failed to persist goal update")
            end
        end
    end
  end

  # ── DELETE /:id/goals/:goal_id — remove a goal ────────────────────────────

  delete "/:id/goals/:goal_id" do
    id = conn.params["id"]
    goal_id = conn.params["goal_id"]
    projects = read_projects()

    case find_project(projects, id) do
      nil ->
        json_error(conn, 404, "not_found", "Project not found")

      project ->
        goals = Map.get(project, "goals", [])

        case Enum.find(goals, fn g -> g["id"] == goal_id end) do
          nil ->
            json_error(conn, 404, "not_found", "Goal not found")

          _goal ->
            new_goals = Enum.reject(goals, fn g -> g["id"] == goal_id end)

            updated_project =
              project
              |> Map.put("goals", new_goals)
              |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

            new_projects =
              Enum.map(projects, fn p -> if p["id"] == id, do: updated_project, else: p end)

            try do
              write_projects(new_projects)
              json(conn, 200, %{deleted: true, goal_id: goal_id})
            rescue
              e ->
                Logger.warning(
                  "[ProjectRoutes] Failed to delete goal #{goal_id}: #{Exception.message(e)}"
                )

                json_error(conn, 500, "internal_error", "Failed to persist goal deletion")
            end
        end
    end
  end

  # ── catch-all ──────────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Project endpoint not found")
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp data_path do
    Path.expand("~/.osa/projects.json")
  end

  defp read_projects do
    path = data_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content),
         true <- is_list(parsed) do
      parsed
    else
      _ -> []
    end
  rescue
    e ->
      Logger.warning("[ProjectRoutes] Failed to read projects file: #{Exception.message(e)}")
      []
  end

  defp write_projects(projects) do
    path = data_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(projects, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)

      {:error, reason} ->
        Logger.warning("[ProjectRoutes] Failed to encode projects: #{inspect(reason)}")
        raise "JSON encode failure"
    end
  end

  defp find_project(projects, id) do
    Enum.find(projects, fn p -> p["id"] == id end)
  end

  defp generate_id(prefix) do
    prefix <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
