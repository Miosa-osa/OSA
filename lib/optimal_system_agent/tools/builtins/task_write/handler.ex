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

  # `run_check` and `complete` can execute a shell command — the task's own
  # acceptance `check`, set earlier via `add`/`update` and run BY THE HARNESS
  # in `Tasks.Check.run/2`. That is the entire point of the feature (an item
  # is only marked done when its check passes, not when the model asserts
  # it), but it means these two actions are NOT the harmless bookkeeping every
  # other `task_write` action is — a `{"type": "command", "command": "..."}`
  # check set by a compromised or injected turn would otherwise bypass the
  # exact permission gate `shell_execute` enforces on the identical command.
  # So route a command-type check through THAT gate before letting `execute/2`
  # reach it, reusing `ShellExecute.Handler.classify_command/1` rather than a
  # second, drifting copy of the same policy.
  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"action" => action} = input, ctx)
      when action in ["run_check", "complete"] do
    session_id = resolve_session_id(input, ctx)
    task_id = Map.get(input, "task_id")

    case command_check_for(session_id, task_id) do
      nil ->
        {:allow, input}

      command ->
        case OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler.classify_command(command) do
          :allow -> {:allow, input}
          {:ask, reason} -> {:ask, reason}
          {:deny, reason} -> {:deny, reason}
        end
    end
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # The command string of `task_id`'s check, IF it is a `"command"`-type
  # check — `nil` for no task, no check, or a non-command check (file_exists /
  # symbol_exists never shell out, so they carry no permission question).
  defp command_check_for(session_id, task_id) when is_binary(task_id) do
    session_id
    |> Tasks.get_tasks()
    |> Enum.find(&(&1.id == task_id))
    |> case do
      %{check: %{type: "command", command: command}} when is_binary(command) -> command
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp command_check_for(_session_id, _task_id), do: nil

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => action} = args, ctx) do
    # The checklist events (`task_created` / `task_updated`) are broadcast on
    # `osa:session:<id>`, which is the topic the TUI's SSE stream subscribes to.
    # This used to ignore `ctx` entirely and fall back to the literal string
    # "default", so unless the model guessed the session uuid every task event
    # was published to `osa:session:default` — a topic with no listener. The
    # tool reported success and the checklist panel never appeared.
    session_id = resolve_session_id(args, ctx)
    do_action(action, session_id, args)
  rescue
    e -> {:error, "TaskWrite error: #{Exception.message(e)}"}
  end

  def execute(_args, _ctx), do: {:error, "Missing required parameter: action"}

  @doc """
  The session the task list belongs to.

  Trust the execution context first — it is the only value guaranteed to match
  the topic the TUI listens on. An explicit `session_id` argument is honoured
  next (cross-session bookkeeping), and the "default" bucket is the last resort
  for context-less callers such as tests and the CLI.
  """
  @spec resolve_session_id(map(), UseContext.t() | any()) :: String.t()
  def resolve_session_id(args, ctx) do
    from_ctx =
      case ctx do
        %{session_id: sid} when is_binary(sid) and sid != "" -> sid
        _ -> nil
      end

    arg_sid =
      case Map.get(args, "session_id") || Map.get(args, "__session_id__") do
        sid when is_binary(sid) and sid != "" -> sid
        _ -> nil
      end

    from_ctx || arg_sid || Constants.default_session()
  end

  # ── Actions ───────────────────────────────────────────────────────────

  defp do_action("add", session_id, %{"title" => title} = args) when is_binary(title) do
    opts =
      %{}
      |> maybe_put(:description, args["description"])
      |> maybe_put(:owner, args["owner"])
      |> maybe_put(:blocked_by, args["blocked_by"])
      |> maybe_put(:metadata, args["metadata"])
      |> maybe_put(:check, args["check"])

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
      :ok ->
        {:ok, "Completed task #{task_id}"}

      {:error, :not_found} ->
        {:error, "Task #{task_id} not found"}

      {:error, {:check_failed, output}} ->
        {:error,
         "Task #{task_id} NOT completed — its acceptance check failed:\n#{output}\n" <>
           "Fix the underlying issue, then try `complete` again."}

      {:error, reason} ->
        {:error, "Failed to complete task: #{inspect(reason)}"}
    end
  end

  defp do_action("complete", _session_id, _args),
    do: {:error, "Missing required parameter: task_id"}

  defp do_action("run_check", session_id, %{"task_id" => task_id}) do
    case Tasks.run_check(session_id, task_id) do
      {:ok, check} ->
        {:ok, "Check for #{task_id}: #{check.status}#{format_check_output(check)}"}

      {:error, :not_found} ->
        {:error, "Task #{task_id} not found"}

      {:error, :no_check} ->
        {:error, "Task #{task_id} has no acceptance check"}
    end
  end

  defp do_action("run_check", _session_id, _args),
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
      |> maybe_put(:check, args["check"])

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

  defp status_suffix(%{status: :in_progress} = task), do: "  [in_progress]" <> check_tag(task)
  defp status_suffix(%{status: :failed, reason: nil} = task), do: "  [failed]" <> check_tag(task)

  defp status_suffix(%{status: :failed, reason: reason} = task),
    do: "  [failed: #{reason}]" <> check_tag(task)

  defp status_suffix(task), do: check_tag(task)

  # `[check: passed|failed|pending]` — only for a task that carries one, so a
  # checkless plan reads exactly as it did before this feature existed.
  defp check_tag(%{check: %{status: status}}), do: "  [check: #{status}]"
  defp check_tag(_), do: ""

  defp format_check_output(%{output: output}) when is_binary(output) and output != "" do
    "\n" <> output
  end

  defp format_check_output(_), do: ""

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
