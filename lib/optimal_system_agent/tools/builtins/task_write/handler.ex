defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `task_write`.

  Split mirrors `FileRead.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (task state is session-local)
    * `execute/2`           — dispatches to the `Tasks` GenServer

  The public `format_task_list/1` helper is exposed so the shim module
  (`TaskWrite`) and tests can continue calling it directly.
  """

  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Tools.Builtins.TaskWrite.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    if action in Constants.actions() do
      {:ok, input}
    else
      valid = Enum.join(Constants.actions(), ", ")
      {:error, "Unknown action: #{action}. Valid: #{valid}", -32_602}
    end
  end

  def validate(%{"action" => _}, _ctx),
    do: {:error, "action must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => action} = args, _ctx) do
    session_id = Map.get(args, "session_id") || Constants.default_session()
    do_action(action, session_id, args)
  rescue
    e -> {:error, "TaskWrite error: #{Exception.message(e)}"}
  end

  def execute(_args, _ctx), do: {:error, "Missing required parameter: action"}

  # ── Actions ───────────────────────────────────────────────────────────

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

  defp do_action("add_dependency", session_id, %{
         "task_id" => task_id,
         "blocker_id" => blocker_id
       }) do
    case Tasks.add_dependency(session_id, task_id, blocker_id) do
      :ok -> {:ok, "Added dependency: #{task_id} blocked by #{blocker_id}"}
      {:error, :not_found} -> {:error, "Task #{task_id} not found"}
      {:error, :blocker_not_found} -> {:error, "Blocker task #{blocker_id} not found"}
      {:error, reason} -> {:error, "Failed to add dependency: #{inspect(reason)}"}
    end
  end

  defp do_action("add_dependency", _session_id, _args),
    do: {:error, "Missing required parameters: task_id, blocker_id"}

  defp do_action("remove_dependency", session_id, %{
         "task_id" => task_id,
         "blocker_id" => blocker_id
       }) do
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

  # Unreachable after validate/2 filters unknown actions, but kept as a
  # safety net so the exhaustive pattern match stays explicit.
  defp do_action(action, _session_id, _args) do
    valid = Enum.join(Constants.actions(), ", ")
    {:error, "Unknown action: #{action}. Valid: #{valid}"}
  end

  # ── Formatting ─────────────────────────────────────────────────────────

  @doc """
  Format a task list for the plain-text LLM result string.

  The string format is also the fallback that `todos.rs::parse_plain_todos`
  can parse when the JSON payload is absent.
  """
  @spec format_task_list([map()]) :: String.t()
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

    if blocked_by != [],
      do: "  [blocked by: #{Enum.join(blocked_by, ", ")}]",
      else: ""
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

  # ── Helpers ────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
