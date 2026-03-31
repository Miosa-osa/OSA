defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite do
  @moduledoc """
  Structured task management tool — TodoWrite equivalent.

  Delegates to the existing TaskTracker GenServer for all operations.
  Enables the LLM to create, track, and manage multi-step work plans.
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.Tasks

  @default_session "default"

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "task_write"

  @impl true
  def description do
    "Create a structured task list for your current session. Tracks progress and shows the user your plan.\n\n" <>
    "## When to Use\n" <>
    "- Complex multi-step tasks (3+ distinct steps)\n" <>
    "- User provides multiple tasks (numbered or comma-separated)\n" <>
    "- After receiving new instructions — capture requirements as tasks immediately\n" <>
    "- When starting work — mark task as in_progress BEFORE beginning\n" <>
    "- After completing work — mark as completed, add follow-up tasks if discovered\n\n" <>
    "## When NOT to Use\n" <>
    "- Single straightforward task (just do it)\n" <>
    "- Trivial tasks (< 3 steps)\n" <>
    "- Purely conversational messages\n\n" <>
    "## Tips\n" <>
    "- Create tasks with clear, specific subjects in imperative form\n" <>
    "- Check existing tasks first to avoid duplicates\n" <>
    "- Mark tasks in_progress before starting, completed when done"
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => [
            "add",
            "add_multiple",
            "start",
            "complete",
            "fail",
            "list",
            "clear",
            "update",
            "add_dependency",
            "remove_dependency",
            "next"
          ],
          "description" => "Operation to perform"
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Session ID (auto-detected if omitted)"
        },
        "task_id" => %{
          "type" => "string",
          "description" => "Task ID (for start/complete/fail/update/add_dependency/remove_dependency)"
        },
        "title" => %{
          "type" => "string",
          "description" => "Task title (for add)"
        },
        "titles" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Multiple task titles (for add_multiple)"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Failure reason (for fail)"
        },
        "description" => %{
          "type" => "string",
          "description" => "Detailed task description"
        },
        "blocked_by" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Task IDs that block this task"
        },
        "owner" => %{
          "type" => "string",
          "description" => "Agent/role that owns this task"
        },
        "metadata" => %{
          "type" => "object",
          "description" => "Arbitrary metadata key-value pairs"
        },
        "blocker_id" => %{
          "type" => "string",
          "description" => "Blocking task ID (for add_dependency/remove_dependency)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => action} = args) do
    session_id = Map.get(args, "session_id") || @default_session
    do_action(action, session_id, args)
  rescue
    e -> {:error, "TaskWrite error: #{Exception.message(e)}"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  # ── Actions ──────────────────────────────────────────────────────

  defp do_action("add", session_id, %{"title" => title} = args) when is_binary(title) do
    opts =
      %{}
      |> maybe_put(:description, args["description"])
      |> maybe_put(:owner, args["owner"])
      |> maybe_put(:blocked_by, args["blocked_by"])
      |> maybe_put(:metadata, args["metadata"])

    case Tasks.add_task(session_id, title, opts) do
      {:ok, id} -> {:ok, "Created task #{id}: #{title}"}
      {:error, reason} -> {:error, "Failed to add task: #{inspect(reason)}"}
    end
  end

  defp do_action("add", _session_id, _args),
    do: {:error, "Missing required parameter: title"}

  defp do_action("add_multiple", session_id, %{"titles" => titles})
       when is_list(titles) and length(titles) > 0 do
    case Tasks.add_tasks(session_id, titles) do
      {:ok, ids} -> {:ok, "Created #{length(ids)} tasks: #{Enum.join(ids, ", ")}"}
      {:error, reason} -> {:error, "Failed to add tasks: #{inspect(reason)}"}
    end
  end

  defp do_action("add_multiple", _session_id, _args),
    do: {:error, "Missing required parameter: titles (non-empty list)"}

  defp do_action("start", session_id, %{"task_id" => task_id}) do
    case Tasks.start_task(session_id, task_id) do
      :ok -> {:ok, "Started task #{task_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, reason} -> {:error, "Failed to start task: #{inspect(reason)}"}
    end
  end

  defp do_action("start", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("complete", session_id, %{"task_id" => task_id}) do
    case Tasks.complete_task(session_id, task_id) do
      :ok -> {:ok, "Completed task #{task_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, reason} -> {:error, "Failed to complete task: #{inspect(reason)}"}
    end
  end

  defp do_action("complete", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("fail", session_id, %{"task_id" => task_id} = args) do
    reason = Map.get(args, "reason", "no reason given")

    case Tasks.fail_task(session_id, task_id, reason) do
      :ok -> {:ok, "Failed task #{task_id}: #{reason}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, err} -> {:error, "Failed to fail task: #{inspect(err)}"}
    end
  end

  defp do_action("fail", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("list", session_id, _args) do
    tasks = Tasks.get_tasks(session_id)
    {:ok, format_task_list(tasks)}
  end

  defp do_action("clear", session_id, _args) do
    Tasks.clear_tasks(session_id)
    {:ok, "Cleared all tasks"}
  end

  defp do_action("update", session_id, %{"task_id" => task_id} = args) do
    updates =
      %{}
      |> maybe_put(:description, args["description"])
      |> maybe_put(:owner, args["owner"])
      |> maybe_put(:metadata, args["metadata"])

    case Tasks.update_task_fields(session_id, task_id, updates) do
      :ok -> {:ok, "Updated task #{task_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, reason} -> {:error, "Failed to update: #{inspect(reason)}"}
    end
  end

  defp do_action("update", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("add_dependency", session_id, %{"task_id" => task_id, "blocker_id" => blocker_id}) do
    case Tasks.add_dependency(session_id, task_id, blocker_id) do
      :ok -> {:ok, "Added dependency: #{task_id} blocked by #{blocker_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, :blocker_not_found} -> {:error, "Blocker task #{blocker_id} not found"}
      {:error, reason} -> {:error, "Failed to add dependency: #{inspect(reason)}"}
    end
  end

  defp do_action("add_dependency", _session_id, _args),
    do: {:error, "Missing required parameters: task_id, blocker_id"}

  defp do_action("remove_dependency", session_id, %{"task_id" => task_id, "blocker_id" => blocker_id}) do
    case Tasks.remove_dependency(session_id, task_id, blocker_id) do
      :ok -> {:ok, "Removed dependency: #{task_id} no longer blocked by #{blocker_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, reason} -> {:error, "Failed to remove dependency: #{inspect(reason)}"}
    end
  end

  defp do_action("remove_dependency", _session_id, _args),
    do: {:error, "Missing required parameters: task_id, blocker_id"}

  defp do_action("next", session_id, _args) do
    case Tasks.get_next_task(session_id) do
      {:ok, nil} -> {:ok, "No unblocked pending tasks."}
      {:ok, task} -> {:ok, "Next task: #{task.id} — #{task.title}"}
    end
  end

  defp do_action(action, _session_id, _args),
    do:
      {:error,
       "Unknown action: #{action}. Valid: add, add_multiple, start, complete, fail, list, clear, update, add_dependency, remove_dependency, next"}

  # ── Formatting ───────────────────────────────────────────────────

  @doc false
  def format_task_list([]), do: "No tasks."

  def format_task_list(tasks) do
    completed = Enum.count(tasks, &(&1.status == :completed))
    total = length(tasks)

    lines =
      Enum.map(tasks, fn task ->
        icon = status_icon(task.status)
        suffix = status_suffix(task)
        owner_tag = if Map.get(task, :owner), do: " @#{task.owner}", else: ""
        blocked_tag = format_blocked_tag(task)
        desc_tag = format_desc_preview(task)
        "  #{icon} #{task.id}: #{task.title}#{owner_tag}#{blocked_tag}#{suffix}#{desc_tag}"
      end)

    "Tasks (#{completed}/#{total} completed):\n#{Enum.join(lines, "\n")}"
  end

  defp status_icon(:completed), do: "✔"
  defp status_icon(:in_progress), do: "◼"
  defp status_icon(:failed), do: "✘"
  defp status_icon(_), do: "◻"

  defp status_suffix(%{status: :in_progress}), do: "  [in_progress]"
  defp status_suffix(%{status: :failed, reason: nil}), do: "  [failed]"
  defp status_suffix(%{status: :failed, reason: reason}), do: "  [failed: #{reason}]"
  defp status_suffix(_), do: ""

  defp format_blocked_tag(task) do
    blocked_by = Map.get(task, :blocked_by) || []

    if blocked_by != [] do
      "  [blocked by: #{Enum.join(blocked_by, ", ")}]"
    else
      ""
    end
  end

  defp format_desc_preview(task) do
    desc = Map.get(task, :description)

    if is_binary(desc) and desc != "" do
      preview = String.slice(desc, 0, 60)
      ellipsis = if String.length(desc) > 60, do: "...", else: ""
      "\n      #{preview}#{ellipsis}"
    else
      ""
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
