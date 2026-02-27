defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite do
  @moduledoc """
  Structured task management tool — TodoWrite equivalent.

  Delegates to the existing TaskTracker GenServer for all operations.
  Enables the LLM to create, track, and manage multi-step work plans.
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.TaskTracker

  @default_session "default"

  @impl true
  def name, do: "task_write"

  @impl true
  def description,
    do: "Create and manage structured task lists. Use to track multi-step work."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["add", "add_multiple", "start", "complete", "fail", "list", "clear"],
          "description" => "Operation to perform"
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Session ID (auto-detected if omitted)"
        },
        "task_id" => %{
          "type" => "string",
          "description" => "Task ID (for start/complete/fail)"
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

  defp do_action("add", session_id, %{"title" => title}) when is_binary(title) do
    case TaskTracker.add_task(session_id, title) do
      {:ok, id} -> {:ok, "Created task #{id}: #{title}"}
      {:error, reason} -> {:error, "Failed to add task: #{inspect(reason)}"}
    end
  end

  defp do_action("add", _session_id, _args),
    do: {:error, "Missing required parameter: title"}

  defp do_action("add_multiple", session_id, %{"titles" => titles})
       when is_list(titles) and length(titles) > 0 do
    case TaskTracker.add_tasks(session_id, titles) do
      {:ok, ids} -> {:ok, "Created #{length(ids)} tasks: #{Enum.join(ids, ", ")}"}
      {:error, reason} -> {:error, "Failed to add tasks: #{inspect(reason)}"}
    end
  end

  defp do_action("add_multiple", _session_id, _args),
    do: {:error, "Missing required parameter: titles (non-empty list)"}

  defp do_action("start", session_id, %{"task_id" => task_id}) do
    case TaskTracker.start_task(session_id, task_id) do
      :ok -> {:ok, "Started task #{task_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, reason} -> {:error, "Failed to start task: #{inspect(reason)}"}
    end
  end

  defp do_action("start", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("complete", session_id, %{"task_id" => task_id}) do
    case TaskTracker.complete_task(session_id, task_id) do
      :ok -> {:ok, "Completed task #{task_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, reason} -> {:error, "Failed to complete task: #{inspect(reason)}"}
    end
  end

  defp do_action("complete", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("fail", session_id, %{"task_id" => task_id} = args) do
    reason = Map.get(args, "reason", "no reason given")

    case TaskTracker.fail_task(session_id, task_id, reason) do
      :ok -> {:ok, "Failed task #{task_id}: #{reason}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, err} -> {:error, "Failed to fail task: #{inspect(err)}"}
    end
  end

  defp do_action("fail", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("list", session_id, _args) do
    tasks = TaskTracker.get_tasks(session_id)
    {:ok, format_task_list(tasks)}
  end

  defp do_action("clear", session_id, _args) do
    TaskTracker.clear_tasks(session_id)
    {:ok, "Cleared all tasks"}
  end

  defp do_action(action, _session_id, _args),
    do: {:error, "Unknown action: #{action}. Valid: add, add_multiple, start, complete, fail, list, clear"}

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
        "  #{icon} #{task.id}: #{task.title}#{suffix}"
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
end
