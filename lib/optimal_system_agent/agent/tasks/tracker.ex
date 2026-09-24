defmodule OptimalSystemAgent.Agent.Tasks.Tracker do
  @moduledoc """
  Live task tracking — persistent, event-driven per-session checklist.

  Tasks progress through :pending → :in_progress → :completed | :failed,
  emitting Events.Bus events on each transition. Auto-extraction from agent
  responses is handled via the Hooks system.

  Persistence: ~/.osa/sessions/{session_id}/tasks.json (atomic .tmp→rename).
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Tasks.Check
  alias OptimalSystemAgent.Agent.Tasks.Persistence

  # ── Task struct ──────────────────────────────────────────────────────────

  defmodule Task do
    @moduledoc false
    defstruct [
      :id,
      :title,
      :description,
      :reason,
      :owner,
      status: :pending,
      tokens_used: 0,
      blocked_by: [],
      metadata: %{},
      created_at: nil,
      started_at: nil,
      completed_at: nil,
      # An acceptance check (`Tasks.Check`), or `nil` for a plan item with none.
      # `complete_task/3` runs this itself before it will transition a checked
      # task to `:completed` -- see the moduledoc.
      check: nil
    ]
  end

  # ── Public: Mutations ─────────────────────────────────────────────────────

  @doc "Add a single task. Returns `{sessions, {:ok, task_id}}`."
  @spec add_task(map(), String.t(), String.t(), map()) :: {map(), {:ok, String.t()}}
  def add_task(sessions, session_id, title, opts \\ %{}) do
    sessions = ensure_session(sessions, session_id)
    task = new_task(title, opts)
    tasks = sessions[session_id] ++ [task]
    sessions = Map.put(sessions, session_id, tasks)
    Persistence.save_tasks(session_id, Enum.map(tasks, &serialize_task/1))

    safe_emit(:system_event, %{
      event: :task_tracker_task_added,
      session_id: session_id,
      task_id: task.id,
      title: title,
      owner: task.owner,
      description: task.description
    })

    safe_emit(:system_event, %{
      event: :task_created,
      task_id: task.id,
      subject: title,
      active_form: task.metadata[:active_form] || title,
      session_id: session_id
    })

    {check_status, check_reason} = check_summary(task)

    # Bridge to the per-session SSE topic so the TUI checklist updates live.
    broadcast_session_event(session_id, :task_created, %{
      task_id: task.id,
      subject: title,
      active_form: active_form_of(task) || title,
      check_status: check_status,
      check_reason: check_reason
    })

    {sessions, {:ok, task.id}}
  end

  @doc "Add multiple tasks at once. Returns `{sessions, {:ok, [task_id]}}`."
  @spec add_tasks(map(), String.t(), [String.t()]) :: {map(), {:ok, [String.t()]}}
  def add_tasks(sessions, session_id, titles) do
    sessions = ensure_session(sessions, session_id)
    new_tasks = Enum.map(titles, &new_task/1)
    tasks = sessions[session_id] ++ new_tasks
    sessions = Map.put(sessions, session_id, tasks)
    Persistence.save_tasks(session_id, Enum.map(tasks, &serialize_task/1))

    ids = Enum.map(new_tasks, & &1.id)

    Enum.each(new_tasks, fn t ->
      safe_emit(:system_event, %{
        event: :task_tracker_task_added,
        session_id: session_id,
        task_id: t.id,
        title: t.title
      })

      safe_emit(:system_event, %{
        event: :task_created,
        task_id: t.id,
        subject: t.title,
        active_form: t.metadata[:active_form] || t.title,
        session_id: session_id
      })

      broadcast_session_event(session_id, :task_created, %{
        task_id: t.id,
        subject: t.title,
        active_form: active_form_of(t) || t.title
      })
    end)

    {sessions, {:ok, ids}}
  end

  @doc "Transition task to :in_progress. Returns `{sessions, :ok | {:error, :not_found}}`."
  @spec start_task(map(), String.t(), String.t()) :: {map(), :ok | {:error, :not_found}}
  def start_task(sessions, session_id, task_id) do
    sessions = ensure_session(sessions, session_id)

    do_update_task(
      sessions,
      session_id,
      task_id,
      fn task ->
        %{task | status: :in_progress, started_at: DateTime.utc_now()}
      end,
      fn task ->
        safe_emit(:system_event, %{
          event: :task_tracker_task_started,
          session_id: session_id,
          task_id: task_id,
          title: task.title
        })

        safe_emit(:system_event, %{
          event: :task_updated,
          task_id: task_id,
          status: "in_progress",
          session_id: session_id
        })

        broadcast_task_update(session_id, task, "in_progress")
      end
    )
  end

  @doc """
  Transition task to `:completed`.

  If the task carries an acceptance `check` (`Tasks.Check`), it is RUN BY THE
  HARNESS first -- never asserted by the model -- and the transition only
  happens when it passes. On failure the task's status is left unchanged and
  its `check` is updated with the failing verdict (visible to `list` /
  `task_checklist_show`), and this returns `{:error, {:check_failed, output}}`
  instead of `:ok`.
  """
  @spec complete_task(map(), String.t(), String.t()) ::
          {map(), :ok | {:error, :not_found | {:check_failed, String.t()}}}
  def complete_task(sessions, session_id, task_id) do
    sessions = ensure_session(sessions, session_id)
    tasks = sessions[session_id] || []

    case Enum.find(tasks, &(&1.id == task_id)) do
      nil ->
        {sessions, {:error, :not_found}}

      %Task{check: nil} ->
        do_complete(sessions, session_id, task_id)

      %Task{check: check} ->
        result = Check.run(check)
        sessions = put_check(sessions, session_id, task_id, result)

        case result.status do
          "passed" ->
            do_complete(sessions, session_id, task_id)

          _ ->
            safe_emit(:system_event, %{
              event: :task_tracker_check_failed,
              session_id: session_id,
              task_id: task_id,
              output: result.output
            })

            {sessions, {:error, {:check_failed, result.output || "check failed"}}}
        end
    end
  end

  defp do_complete(sessions, session_id, task_id) do
    do_update_task(
      sessions,
      session_id,
      task_id,
      fn task ->
        %{task | status: :completed, completed_at: DateTime.utc_now()}
      end,
      fn task ->
        safe_emit(:system_event, %{
          event: :task_tracker_task_completed,
          session_id: session_id,
          task_id: task_id,
          title: task.title
        })

        safe_emit(:system_event, %{
          event: :task_updated,
          task_id: task_id,
          status: "completed",
          session_id: session_id
        })

        broadcast_task_update(session_id, task, "completed")
      end
    )
  end

  @doc """
  Run a task's acceptance check BY THE HARNESS, without completing the task.

  Lets the model (or an operator) see the current verdict before attempting
  `complete_task/3` -- useful mid-work, since a failing check should not be a
  surprise at completion time. Returns `{:error, :no_check}` for a task with
  none.
  """
  @spec run_check(map(), String.t(), String.t()) ::
          {map(), {:ok, map()} | {:error, :not_found | :no_check}}
  def run_check(sessions, session_id, task_id) do
    sessions = ensure_session(sessions, session_id)
    tasks = sessions[session_id] || []

    case Enum.find(tasks, &(&1.id == task_id)) do
      nil ->
        {sessions, {:error, :not_found}}

      %Task{check: nil} ->
        {sessions, {:error, :no_check}}

      %Task{check: check} ->
        result = Check.run(check)
        new_sessions = put_check(sessions, session_id, task_id, result)

        safe_emit(:system_event, %{
          event: :task_tracker_check_run,
          session_id: session_id,
          task_id: task_id,
          status: result.status
        })

        {new_sessions, {:ok, result}}
    end
  end

  # Writes the check's verdict onto the task AND broadcasts it -- the single
  # write path for both `run_check/3` and `complete_task/3`'s failure branch,
  # so a check result reaches the TUI's Plan panel however it was reached
  # instead of only when it happens to also complete the task.
  defp put_check(sessions, session_id, task_id, check) do
    {new_sessions, result} =
      do_update_task(
        sessions,
        session_id,
        task_id,
        fn task -> %{task | check: check} end,
        fn task -> broadcast_task_update(session_id, task, to_string(task.status)) end
      )

    case result do
      :ok -> new_sessions
      # `do_update_task` returns `sessions` unchanged on `:not_found`, and the
      # two callers already re-check existence before ever reaching this
      # function -- so this branch is unreachable in practice, kept only so a
      # future third caller fails loudly instead of silently dropping a write.
      {:error, :not_found} -> new_sessions
    end
  end

  @doc "Transition task to :failed."
  @spec fail_task(map(), String.t(), String.t(), String.t()) ::
          {map(), :ok | {:error, :not_found}}
  def fail_task(sessions, session_id, task_id, reason) do
    sessions = ensure_session(sessions, session_id)

    do_update_task(
      sessions,
      session_id,
      task_id,
      fn task ->
        %{task | status: :failed, reason: reason, completed_at: DateTime.utc_now()}
      end,
      fn task ->
        safe_emit(:system_event, %{
          event: :task_tracker_task_failed,
          session_id: session_id,
          task_id: task_id,
          title: task.title,
          reason: reason
        })

        safe_emit(:system_event, %{
          event: :task_updated,
          task_id: task_id,
          status: "failed",
          session_id: session_id
        })

        broadcast_task_update(session_id, task, "failed")
      end
    )
  end

  @doc "Update task fields (description, owner, metadata)."
  @spec update_fields(map(), String.t(), String.t(), map()) :: {map(), :ok | {:error, :not_found}}
  def update_fields(sessions, session_id, task_id, updates) do
    sessions = ensure_session(sessions, session_id)

    allowed =
      updates
      |> Map.take([:description, :owner, :metadata, :check])
      |> normalize_check_update()

    do_update_task(
      sessions,
      session_id,
      task_id,
      fn task ->
        Map.merge(task, allowed)
      end,
      fn task ->
        safe_emit(:system_event, %{
          event: :task_tracker_task_updated,
          session_id: session_id,
          task_id: task_id,
          fields: Map.keys(allowed),
          title: task.title
        })

        # A newly-attached (or replaced) check resets to "pending" -- worth a
        # push so the Plan panel shows it immediately rather than waiting for
        # the next unrelated status change or an explicit `run_check`.
        if Map.has_key?(allowed, :check) do
          broadcast_task_update(session_id, task, to_string(task.status))
        end
      end
    )
  end

  @doc "Record token usage against a task. Fire-and-forget, returns new sessions."
  @spec record_tokens(map(), String.t(), String.t(), non_neg_integer()) :: map()
  def record_tokens(sessions, session_id, task_id, count) do
    sessions = ensure_session(sessions, session_id)

    {new_sessions, _} =
      do_update_task(
        sessions,
        session_id,
        task_id,
        fn task ->
          %{task | tokens_used: task.tokens_used + count}
        end,
        fn _task -> :ok end
      )

    new_sessions
  end

  @doc "Add a dependency to a task."
  @spec add_dependency(map(), String.t(), String.t(), String.t()) ::
          {map(), :ok | {:error, :not_found | :blocker_not_found}}
  def add_dependency(sessions, session_id, task_id, blocker_id) do
    sessions = ensure_session(sessions, session_id)
    tasks = sessions[session_id] || []

    if not Enum.any?(tasks, &(&1.id == blocker_id)) do
      {sessions, {:error, :blocker_not_found}}
    else
      do_update_task(
        sessions,
        session_id,
        task_id,
        fn task ->
          blocked_by = task.blocked_by || []

          if blocker_id in blocked_by,
            do: task,
            else: %{task | blocked_by: blocked_by ++ [blocker_id]}
        end,
        fn task ->
          safe_emit(:system_event, %{
            event: :task_tracker_dependency_added,
            session_id: session_id,
            task_id: task_id,
            blocker_id: blocker_id,
            title: task.title
          })
        end
      )
    end
  end

  @doc "Remove a dependency from a task."
  @spec remove_dependency(map(), String.t(), String.t(), String.t()) ::
          {map(), :ok | {:error, :not_found}}
  def remove_dependency(sessions, session_id, task_id, blocker_id) do
    sessions = ensure_session(sessions, session_id)

    do_update_task(
      sessions,
      session_id,
      task_id,
      fn task ->
        %{task | blocked_by: (task.blocked_by || []) -- [blocker_id]}
      end,
      fn task ->
        safe_emit(:system_event, %{
          event: :task_tracker_dependency_removed,
          session_id: session_id,
          task_id: task_id,
          blocker_id: blocker_id,
          title: task.title
        })
      end
    )
  end

  @doc "Clear all tasks for a session."
  @spec clear_tasks(map(), String.t()) :: map()
  def clear_tasks(sessions, session_id) do
    sessions = Map.put(sessions, session_id, [])
    Persistence.save_tasks(session_id, [])

    safe_emit(:system_event, %{event: :task_tracker_tasks_cleared, session_id: session_id})
    sessions
  end

  # ── Public: Queries ───────────────────────────────────────────────────────

  @doc "Get all tasks for a session."
  @spec get_tasks(map(), String.t()) :: [%Task{}]
  def get_tasks(sessions, session_id) do
    sessions = ensure_session(sessions, session_id)
    sessions[session_id] || []
  end

  @doc "Get the next unblocked pending task."
  @spec get_next_task(map(), String.t()) :: {:ok, %Task{} | nil}
  def get_next_task(sessions, session_id) do
    sessions = ensure_session(sessions, session_id)
    tasks = sessions[session_id] || []

    next =
      Enum.find(tasks, fn task ->
        task.status == :pending and dependencies_met?(task, tasks)
      end)

    {:ok, next}
  end

  @doc "Convert a task to a UI map."
  @spec task_to_map(%Task{}) :: map()
  def task_to_map(%Task{} = task) do
    {check_status, check_reason} = check_summary(task)

    %{
      id: task.id,
      subject: task.title,
      status: to_string(task.status),
      active_form: task.metadata[:active_form],
      check_status: check_status,
      check_reason: check_reason
    }
  end

  @doc """
  Progress across a session's checklist: `passed checks / items`.

  An item counts as "passed" when it either has no acceptance check and is
  `:completed` (the pre-existing, model-asserted notion of done), or has a
  check whose last harness-run `status` is `"passed"`. Exposed so the
  homeostat sibling (and the TUI plan view) can read real, harness-verified
  progress instead of a raw completed-count that a check-carrying task could
  satisfy just by being marked complete.
  """
  @spec plan_progress(map(), String.t()) :: %{
          passed: non_neg_integer(),
          total: non_neg_integer(),
          fraction: float()
        }
  def plan_progress(sessions, session_id) do
    tasks = get_tasks(sessions, session_id)
    total = length(tasks)
    passed = Enum.count(tasks, &item_passed?/1)
    fraction = if total > 0, do: passed / total, else: 1.0

    %{passed: passed, total: total, fraction: fraction}
  end

  defp item_passed?(%Task{check: nil, status: :completed}), do: true
  defp item_passed?(%Task{check: %{status: "passed"}}), do: true
  defp item_passed?(_), do: false

  # ── Public: Extraction ────────────────────────────────────────────────────

  @doc """
  Extract task titles from a text response.
  Parses numbered lists and markdown checkboxes. Caps at 20, 5–120 chars.
  """
  @spec extract_from_response(String.t()) :: [String.t()]
  def extract_from_response(text) when is_binary(text) do
    numbered = Regex.scan(~r/^\s*\d+\.\s+(.+)$/m, text, capture: :all_but_first)
    checkboxes = Regex.scan(~r/^\s*-\s*\[[ x]?\]\s+(.+)$/mi, text, capture: :all_but_first)

    (numbered ++ checkboxes)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn t -> String.length(t) >= 5 and String.length(t) <= 120 end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  def extract_from_response(_), do: []

  # ── Serialization ──────────────────────────────────────────────────────────

  @doc false
  def serialize_task(%Task{} = t) do
    %{
      "id" => t.id,
      "title" => t.title,
      "description" => t.description,
      "reason" => t.reason,
      "owner" => t.owner,
      "status" => to_string(t.status),
      "tokens_used" => t.tokens_used,
      "blocked_by" => t.blocked_by || [],
      "metadata" => t.metadata || %{},
      "created_at" => if(t.created_at, do: DateTime.to_iso8601(t.created_at)),
      "started_at" => if(t.started_at, do: DateTime.to_iso8601(t.started_at)),
      "completed_at" => if(t.completed_at, do: DateTime.to_iso8601(t.completed_at)),
      "check" => Check.serialize(t.check)
    }
  end

  @doc false
  def deserialize_task(map) when is_map(map) do
    %Task{
      id: map["id"],
      title: map["title"],
      description: map["description"],
      reason: map["reason"],
      owner: map["owner"],
      status: String.to_existing_atom(map["status"] || "pending"),
      tokens_used: map["tokens_used"] || 0,
      blocked_by: map["blocked_by"] || [],
      metadata: map["metadata"] || %{},
      created_at: parse_datetime(map["created_at"]),
      started_at: parse_datetime(map["started_at"]),
      completed_at: parse_datetime(map["completed_at"]),
      check: Check.deserialize(map["check"])
    }
  rescue
    _ ->
      %Task{
        id: map["id"] || "unknown",
        title: map["title"] || "unknown",
        status: :pending,
        blocked_by: [],
        metadata: %{}
      }
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp new_task(title, opts \\ %{}) do
    %Task{
      id: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower),
      title: title,
      description: Map.get(opts, :description),
      owner: Map.get(opts, :owner),
      status: :pending,
      tokens_used: 0,
      blocked_by: Map.get(opts, :blocked_by, []),
      metadata: Map.get(opts, :metadata, %{}),
      created_at: DateTime.utc_now(),
      check: Check.normalize(Map.get(opts, :check))
    }
  end

  # `update_fields/4` lets a check be attached (or replaced) on an existing
  # task. Replacing one resets it to "pending" via `Check.normalize/1` -- the
  # previous verdict describes a spec that no longer exists.
  defp normalize_check_update(%{check: raw} = allowed),
    do: %{allowed | check: Check.normalize(raw)}

  defp normalize_check_update(allowed), do: allowed

  defp do_update_task(sessions, session_id, task_id, update_fn, notify_fn) do
    tasks = sessions[session_id] || []
    idx = Enum.find_index(tasks, &(&1.id == task_id))

    case idx do
      nil ->
        {sessions, {:error, :not_found}}

      i ->
        task = Enum.at(tasks, i)
        updated = update_fn.(task)
        tasks = List.replace_at(tasks, i, updated)
        sessions = Map.put(sessions, session_id, tasks)
        Persistence.save_tasks(session_id, Enum.map(tasks, &serialize_task/1))
        notify_fn.(updated)
        {sessions, :ok}
    end
  end

  defp dependencies_met?(%Task{blocked_by: blocked_by}, all_tasks) do
    (blocked_by || [])
    |> Enum.all?(fn blocker_id ->
      case Enum.find(all_tasks, &(&1.id == blocker_id)) do
        nil -> true
        blocker -> blocker.status == :completed
      end
    end)
  end

  defp ensure_session(sessions, session_id) do
    if Map.has_key?(sessions, session_id) do
      sessions
    else
      tasks =
        session_id
        |> Persistence.load_tasks()
        |> Enum.map(&deserialize_task/1)

      Map.put(sessions, session_id, tasks)
    end
  end

  # Bridge a task event onto the per-session PubSub topic the TUI SSE stream
  # subscribes to ("osa:session:#{id}"). Mirrors Orchestrator.emit_event/2:
  # wraps the payload as a :system_event so the SSE loop derives the sub-event
  # type (task_created / task_updated / …) via to_string(event). The Events.Bus
  # emit above still fires — this is additive, not a replacement.
  defp broadcast_session_event(session_id, event, extra)
       when is_binary(session_id) and is_map(extra) do
    payload =
      extra
      |> Map.put(:type, :system_event)
      |> Map.put(:event, event)
      |> Map.put(:session_id, session_id)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, payload}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp broadcast_session_event(_session_id, _event, _extra), do: :ok

  # The one place `:task_updated` is broadcast, so `check_status`/`check_reason`
  # cannot be forgotten at one call site and present at another — every status
  # transition (start/complete/fail) AND every check-only change (a failed
  # `complete_task/3` attempt, an explicit `run_check/3`) goes through this,
  # carrying the task's CURRENT check verdict alongside whatever status word
  # the caller is reporting. Flat top-level keys, matching `task_created`'s
  # shape: the SSE bridge (`SessionRoutes.session_sse_loop/2`) JSON-encodes a
  # `%{type: :system_event, event: sub}` payload VERBATIM as the event's `data`
  # body, so these keys are what the Rust client's `sse.rs` parses directly —
  # no `data` nesting (that shape is `task_checklist_show`'s, not this one's).
  defp broadcast_task_update(session_id, %Task{} = task, status) do
    {check_status, check_reason} = check_summary(task)

    broadcast_session_event(session_id, :task_updated, %{
      task_id: task.id,
      status: status,
      active_form: active_form_of(task),
      check_status: check_status,
      check_reason: check_reason
    })
  end

  # `{status, reason}` for the task's check, or `{nil, nil}` for a checkless
  # task. `reason` is populated ONLY on failure -- a passed/pending check has
  # nothing worth a line in the checklist, and `Check.run/2`'s `output` on a
  # PASS is often just the command's stdout, not a "reason" in any useful
  # sense.
  defp check_summary(%Task{check: nil}), do: {nil, nil}

  defp check_summary(%Task{check: %{status: status} = check}) do
    {status, check_reason_line(status, Map.get(check, :output))}
  end

  defp check_summary(_), do: {nil, nil}

  # First line only, capped -- this is broadcast on every check run and
  # rendered inline in a checklist row, not the tool-result console a full
  # command log belongs in. `Check.run/2` already caps `output` at 4,000
  # chars; this caps it again, harder, for the one-line UI surface.
  @check_reason_max_chars 120

  # Collapsed to ONE line rather than taking the first, because the first line
  # of a failed `"command"` check's output is `Check.run/2`'s own "exit N"
  # header (`Tasks.Check.run_command/2`), not the command's actual output --
  # a checklist row reading "exit 1" tells the reader nothing a red ✗ did not
  # already say.
  defp check_reason_line("failed", output) when is_binary(output) and output != "" do
    output
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @check_reason_max_chars)
  end

  defp check_reason_line(_status, _output), do: nil

  # Read :active_form from task metadata, tolerating both atom and string keys
  # (metadata round-trips through JSON persistence, which stringifies keys).
  defp active_form_of(%Task{metadata: meta}) when is_map(meta) do
    Map.get(meta, :active_form) || Map.get(meta, "active_form")
  end

  defp active_form_of(_), do: nil

  defp safe_emit(event_type, payload) do
    spawn(fn ->
      try do
        Bus.emit(event_type, payload)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
