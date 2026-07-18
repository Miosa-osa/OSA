defmodule OptimalSystemAgent.Channels.HTTP.API.TasksRoutes do
  @moduledoc """
  Task-tracker introspection routes for the OSA HTTP API.

  Forwarded prefix: /tasks-list

  Effective routes:
    GET /  (forwarded as GET /tasks-list)
      Lists the current tracker tasks so the TUI `/tasks` panel can render
      them grouped by status. Tasks live per-session inside
      `OptimalSystemAgent.Agent.Tasks` (the Tracker subsystem), so this
      aggregates across every known runtime session. Pass `?session=<id>`
      to scope to a single session.

  Response shape:

      {
        "tasks": [
          {"id": "t_ab12", "description": "Implement auth", "status": "pending", "priority": "normal"},
          ...
        ]
      }

  The Tracker `Task` struct exposes `id`, `title`, `description`, an atom
  `status` (`:pending | :in_progress | :completed | :failed`) and a free-form
  `metadata` map. There is no first-class priority field, so priority is read
  from `metadata[:priority]` (or the string key) and defaults to `"normal"`.
  The atom status is stringified so the TUI receives clean JSON. On any
  failure the call is wrapped in try/rescue and returns an empty list — the
  endpoint never 500s the TUI.
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Runtime.SessionManager

  plug(:match)
  plug(:dispatch)

  # ── GET / — current tracker tasks ───────────────────────────────────

  get "/" do
    tasks =
      try do
        conn.params
        |> Map.get("session")
        |> session_ids()
        |> Enum.flat_map(&safe_get_tasks/1)
        |> Enum.map(&serialize_task/1)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    json(conn, 200, %{tasks: tasks})
  end

  # ── catch-all ───────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Tasks endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  # A single session when scoped via `?session=`, otherwise every known
  # runtime session id (live + tracked). Deduped so a session that appears
  # in both lists is not double-counted.
  defp session_ids(session) when is_binary(session) and session != "", do: [session]

  defp session_ids(_) do
    (SessionManager.list_session_ids() ++ SessionManager.live_session_ids())
    |> Enum.uniq()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Tasks for one session; never lets a bad session id break the aggregate.
  defp safe_get_tasks(session_id) do
    case Tasks.get_tasks(session_id) do
      list when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Normalize a Tracker task struct into a clean, JSON-safe map. `status` is
  # an atom and must be stringified; priority is derived from metadata.
  defp serialize_task(task) do
    %{
      id: stringify(field(task, :id)),
      description: stringify(field(task, :description) || field(task, :title)),
      status: stringify(field(task, :status) || :pending),
      priority: priority_of(task)
    }
  end

  # Read either a struct/map atom key. Structs are maps, so Map.get works for
  # both; falls back to nil for anything unexpected.
  defp field(task, key) when is_map(task), do: Map.get(task, key)
  defp field(_task, _key), do: nil

  # Priority is not a first-class Task field — pull it from metadata (atom or
  # string key), defaulting to "normal".
  defp priority_of(task) do
    meta = field(task, :metadata) || %{}

    value =
      cond do
        is_map(meta) and Map.has_key?(meta, :priority) -> meta[:priority]
        is_map(meta) and Map.has_key?(meta, "priority") -> meta["priority"]
        true -> "normal"
      end

    case stringify(value) do
      nil -> "normal"
      "" -> "normal"
      s -> s
    end
  end

  # Stringify atom/binary values (nil-safe) so the TUI never sees raw atoms.
  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v), do: to_string(v)
end
