defmodule OptimalSystemAgent.Agent.TaskNotifications do
  @moduledoc """
  Background task-notification queue (WS6 — Claude Code parity).

  When a background shell command or background subagent completes, its result
  must RE-ENTER the agent loop — not just sit in the transcript. The producer
  (`Agent.BackgroundNotifier`) queues a notification here, then pokes the
  parent `Loop`:

    * if the loop is BUSY, the running ReactLoop drains this queue at the same
      step boundary where it drains mid-turn steers, so the model sees the
      completion within the SAME turn;
    * if the loop is IDLE, `Loop.poke/1` services the queue by running a
      synthetic turn, so the agent reacts unprompted.

  Notifications are injected as `<task-notification>` XML system messages
  (CC `constants/xml.ts` contract: task-id, tool-use-id, status, output-file,
  summary, usage).

  Storage mirrors `Loop.Steer` — and for the same reason: the loop process is
  blocked in `handle_call` for the whole turn, so only ETS is visible mid-turn.
  Rows are `{{session_id, seq}, map}` in the `:osa_task_notifications`
  `:ordered_set` (FIFO reserve, followed by durable acknowledgement). The
  `:osa_task_notified` set holds per-task check-and-set flags so a
  `bash_output` poll and the completion broadcast racing yield exactly ONE
  notification per task.
  """
  require Logger

  alias OptimalSystemAgent.Agent.DurableInbox

  @table :osa_task_notifications
  @notified_table :osa_task_notified
  @poke_table :osa_task_notification_pokes
  @coalesce_ms 25
  @claim_retries 20
  @claim_retry_ms 5

  @type notification :: map()

  @doc "Enqueue a task notification for `session_id`. Never raises."
  @spec queue(String.t(), notification()) :: :ok | {:error, term()}
  def queue(session_id, notification) when is_binary(session_id) and is_map(notification) do
    DurableInbox.append(@table, session_id, :task_notifications, notification)
  rescue
    ArgumentError ->
      Logger.warning("[task-notif] queue table missing — notification dropped for #{session_id}")
      :ok
  end

  @doc "Claim and durably enqueue one task notification exactly once."
  @spec queue_once(String.t(), notification()) :: :ok | :already_notified | {:error, term()}
  def queue_once(session_id, notification) when is_binary(session_id) and is_map(notification) do
    task_id = to_string(notification[:task_id] || notification["task_id"] || "")

    if task_id in ["", "unknown"] do
      queue(session_id, notification)
    else
      claim_and_queue(session_id, task_id, notification, @claim_retries)
    end
  end

  @doc "Remove and return all queued notifications for `session_id`, oldest first."
  @spec drain(String.t()) :: [notification()]
  def drain(session_id) when is_binary(session_id) do
    DurableInbox.drain(@table, session_id, :task_notifications)
  rescue
    ArgumentError -> []
  end

  @doc "Number of notifications currently queued for `session_id`."
  @spec count(String.t()) :: non_neg_integer()
  def count(session_id) when is_binary(session_id) do
    DurableInbox.count(@table, session_id, :task_notifications)
  rescue
    ArgumentError -> 0
  end

  @doc false
  def checkout(session_id),
    do: DurableInbox.checkout(@table, session_id, :task_notifications)

  @doc false
  def acknowledge(session_id, receipt),
    do: DurableInbox.acknowledge(@table, session_id, :task_notifications, receipt)

  @doc false
  def acknowledge(session_id, receipt, notifications) when is_list(notifications) do
    case acknowledge(session_id, receipt) do
      :ok ->
        receipt_id = Enum.map_join(receipt, ",", &to_string/1)

        Enum.each(notifications, fn notification ->
          case notification[:task_id] || notification["task_id"] do
            id when is_binary(id) and id != "" ->
              OptimalSystemAgent.Agent.ExecutionControl.delivery(
                id,
                receipt_id,
                :acknowledged
              )

              OptimalSystemAgent.Agent.ExecutionControl.broadcast(id, session_id)

            _ ->
              :ok
          end
        end)

        :ok

      error ->
        error
    end
  end

  @doc false
  def release(session_id, receipt), do: DurableInbox.release(@table, session_id, receipt)

  @doc "Whether any notifications are pending for `session_id`."
  @spec pending?(String.t()) :: boolean()
  def pending?(session_id) when is_binary(session_id), do: count(session_id) > 0
  def pending?(_), do: false

  @doc """
  Ask whether a result is sitting unread for `session_id` and, if one is, poke
  the loop so it gets read. Returns `:unread` or `:clear`.

  ## The window this closes

  This queue is drained at exactly two sites: a busy turn's step boundary
  (`ReactLoop.inject_pending_task_notifications/1`) and the idle poke
  (`Loop.handle_cast(:poke, %{status: :idle})`). A turn has a LAST step
  boundary, and everything after it — the finalize block, and the whole
  plan-mode return path, which never enters `run_and_reply/1` at all — runs with
  `status` still non-`:idle`. A `:poke` landing in that window met the catch-all
  `handle_cast(:poke, state)` and was dropped, with nothing re-poking.
  `pending?/1` was the obvious guard and had no production caller, so no turn
  boundary ever asked.

  ## Why the queue and not the poke

  The poke is ADVISORY; the queue is the FACT. Re-queuing a dropped poke would
  fix only the pokes we know went missing. Asking the queue at every turn
  completion also covers a poke that raced the status flip, and a future caller
  that queues a result and forgets to poke at all — the failure mode that
  produced this one.

  This is called from the tail of a turn, so it never raises: a poke that cannot
  be delivered (the loop is shutting down, its name is deregistered) leaves the
  notification queued for the next incarnation, which is the same place a
  dropped poke leaves it, and reports `:clear` rather than claiming a delivery
  it did not make.

  It cannot spin. A consumer claims live entries before starting the synthetic
  turn, then acknowledges them after persisting their incorporation.
  """
  @spec settle(String.t() | nil) :: :unread | :clear
  def settle(session_id) when is_binary(session_id) do
    if pending?(session_id) do
      poker().poke(session_id)
      :unread
    else
      :clear
    end
  rescue
    e ->
      Logger.debug("[TaskNotifications] settle/1 could not poke #{session_id}: #{inspect(e)}")
      :clear
  catch
    kind, reason ->
      Logger.debug("[TaskNotifications] settle/1 caught #{kind}: #{inspect(reason)}")
      :clear
  end

  def settle(_), do: :clear

  @doc "Wake the loop after a short deduplicated completion-coalescing window."
  @spec poke_after_batch(String.t()) :: :ok
  def poke_after_batch(session_id) when is_binary(session_id) do
    if :ets.insert_new(@poke_table, {session_id, true}) do
      case Task.Supervisor.start_child(OptimalSystemAgent.TaskSupervisor, fn ->
             Process.sleep(@coalesce_ms)
             :ets.delete(@poke_table, session_id)
             poker().poke(session_id)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          :ets.delete(@poke_table, session_id)
          Logger.warning("[task-notif] could not schedule coalesced poke: #{inspect(reason)}")
          poker().poke(session_id)
      end
    end

    :ok
  rescue
    ArgumentError ->
      poker().poke(session_id)
      :ok
  end

  # Injected by the same convention `:background_manager` and `:subagent_roster`
  # already use. Also breaks what would otherwise be a compile-time cycle back
  # into `Agent.Loop`.
  defp poker do
    Application.get_env(
      :optimal_system_agent,
      :notification_poker,
      OptimalSystemAgent.Agent.Loop
    )
  end

  @doc """
  Check-and-set the per-task \"notified\" flag. Returns `true` exactly once per
  `task_id` — the winner is the only path allowed to notify (completion
  broadcast vs a `bash_output` poll that already saw the terminal status).
  """
  @spec mark_notified(String.t()) :: boolean()
  def mark_notified(task_id) when is_binary(task_id) do
    :ets.insert_new(@notified_table, {task_id, :notified, System.system_time(:millisecond)})
  rescue
    ArgumentError -> true
  end

  @doc "Release a notification claim when durable queueing fails."
  @spec clear_notified(String.t()) :: :ok
  def clear_notified(task_id) when is_binary(task_id) do
    :ets.delete(@notified_table, task_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp claim_and_queue(session_id, task_id, notification, retries_left) do
    claim = {task_id, :claiming, System.system_time(:millisecond)}

    if :ets.insert_new(@notified_table, claim) do
      case queue(session_id, notification) do
        :ok ->
          :ets.insert(@notified_table, {task_id, :notified, System.system_time(:millisecond)})
          :ok

        {:error, reason} = error ->
          :ets.delete_object(@notified_table, claim)
          Logger.error("[task-notif] durable claim failed for #{task_id}: #{inspect(reason)}")
          error
      end
    else
      await_claim(session_id, task_id, notification, retries_left)
    end
  end

  defp await_claim(_session_id, _task_id, _notification, 0), do: {:error, :claim_timeout}

  defp await_claim(session_id, task_id, notification, retries_left) do
    case :ets.lookup(@notified_table, task_id) do
      [{^task_id, :claiming, _}] ->
        Process.sleep(@claim_retry_ms)
        claim_and_queue(session_id, task_id, notification, retries_left - 1)

      [] ->
        claim_and_queue(session_id, task_id, notification, retries_left - 1)

      _ ->
        :already_notified
    end
  end

  @doc """
  Build the injected message list: one system message per notification,
  wrapping a `<task-notification>` XML block (CC parity).
  """
  @spec to_messages([notification()]) :: [map()]
  def to_messages(notifications) when is_list(notifications) do
    case notifications do
      [] -> []
      list -> [%{role: "system", content: Enum.map_join(list, "\n\n", &to_xml/1)}]
    end
  end

  # Element order is fixed by the CC `constants/xml.ts` contract. Declared once
  # here so the builder can never emit a duplicate or out-of-order element.
  @elements [
    {"task-id", :task_id},
    {"tool-use-id", :tool_use_id},
    {"status", :status},
    {"output-file", :output_file},
    {"summary", :summary},
    {"usage", :usage}
  ]

  @root "task-notification"

  @doc "The ordered element names of a `<task-notification>` block."
  @spec elements() :: [String.t()]
  def elements, do: Enum.map(@elements, &elem(&1, 0))

  @doc "The root tag name of a notification block."
  @spec root_tag() :: String.t()
  def root_tag, do: @root

  @doc """
  Render one notification as its `<task-notification>` XML block.

  Built structurally from `@elements`: each element is emitted at most once, in
  a fixed order, and every VALUE is XML-escaped. The escaping is not cosmetic —
  `summary` embeds up to 400 bytes of raw command output tail, so a build log
  containing `<`, `>` or `&` (a Go/Elixir type, an HTML fragment, a shell
  redirect) used to be spliced in verbatim and could produce a block whose tags
  no longer matched. Mismatched or duplicated tags are now impossible by
  construction.
  """
  @spec to_xml(notification()) :: String.t()
  def to_xml(n) when is_map(n) do
    fields =
      @elements
      |> Enum.map(fn {tag, key} -> {tag, n[key]} end)
      |> Enum.reject(fn {_tag, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {tag, v} -> "  <#{tag}>#{escape(xml_value(v))}</#{tag}>" end)
      |> Enum.join("\n")

    "<#{@root}>\n" <>
      fields <>
      "\n</#{@root}>\n" <>
      completion_instruction(n[:status])
  end

  # The instruction that decides what the user actually gets when a teammate
  # finishes — the single most valuable moment in the whole delegation flow.
  #
  # The old text ("react to this result if it affects your current work") is
  # satisfied by saying nothing, so the common outcome was a bare "the agent
  # finished" or a verbatim paste of the child's report. Neither is an account:
  # the first withholds the work, the second makes the user do the reading the
  # delegation was supposed to save them. So the instruction now DEMANDS a
  # synthesis, names its four parts, and forbids the two failure modes by name.
  @completion_instruction "[A background task finished. Now give the user an ACCOUNT of it " <>
                            "IN YOUR OWN WORDS, in the context of what they asked you for: what it " <>
                            "found, what it changed, what that means for the work in progress, and " <>
                            "anything in it you disagree with. Do NOT paste, quote or reformat the " <>
                            "report — you read it so the user does not have to. Do NOT reply with " <>
                            "only \"the agent finished\" or a status line; a status is not an " <>
                            "account. If the result changes your plan, say how. The full output is " <>
                            "in the output-file (readable with the read tool) if you need detail " <>
                            "beyond the summary above. Do not poll for this task again. This block " <>
                            "is internal harness plumbing — never quote, repeat or paraphrase its " <>
                            "markup in your reply to the user.]"

  # The same block used to ride EVERY notification, whatever the outcome. So a
  # task that crashed, timed out, was cancelled, or went quiet was handed to the
  # model under an instruction that asks what it "found", what it "changed", and
  # what that "means for the work in progress" — four prompts that all presuppose
  # work happened. A model answering them faithfully about a failed run produces
  # a confident account of a task that did nothing, which is worse than silence:
  # the user believes the thing is done.
  #
  # A non-terminal-success status therefore gets its own instruction, whose first
  # demand is that the failure be reported AS a failure and not folded into a
  # progress report.
  @failure_instruction "[A background task did NOT succeed. Tell the user that PLAINLY and " <>
                         "FIRST — name the task, say it failed (or stalled, or was cancelled) " <>
                         "and say what the failure was. Do NOT describe it as progress, do NOT " <>
                         "summarize partial output as if it were the result, and do NOT quietly " <>
                         "move on to something else as though the work were done. Then say what " <>
                         "it means: whether anything the task was supposed to produce is now " <>
                         "missing, whether you can recover it another way, and what you propose " <>
                         "to do next. If you are going to retry, say so before retrying. The " <>
                         "full output is in the output-file (readable with the read tool). Do " <>
                         "not poll for this task again. This block is internal harness plumbing " <>
                         "— never quote, repeat or paraphrase its markup in your reply to the " <>
                         "user.]"

  @doc """
  The trailing instruction appended to every `<task-notification>` block.

  Zero-arity keeps the success text for callers that only ever meant the happy
  path (and for the tests that pin it).
  """
  @spec completion_instruction() :: String.t()
  def completion_instruction, do: @completion_instruction

  @doc """
  The trailing instruction for a notification with `status`.

  Only a genuinely successful terminal status gets the "give an account of what
  it found and changed" text. `:failed`, `:stalled`, `:cancelled`, `:timeout`
  and anything unrecognised get `failure_instruction/0`, because every one of
  them describes a task whose output the model must not present as work.

  `:completed`, `:done`, `:ok` and `nil` (an untyped notification, e.g. a
  background shell command that exited cleanly) read as success.
  """
  @spec completion_instruction(term()) :: String.t()
  def completion_instruction(status) do
    if success_status?(status), do: @completion_instruction, else: @failure_instruction
  end

  @doc "The instruction used when a task did not succeed."
  @spec failure_instruction() :: String.t()
  def failure_instruction, do: @failure_instruction

  @success_statuses ~w(completed done ok success succeeded)

  # Unknown statuses fall to the failure branch on purpose: mislabelling a
  # success as a failure costs one over-cautious sentence, and mislabelling a
  # failure as a success is the exact outcome this exists to prevent.
  defp success_status?(nil), do: true

  defp success_status?(status) when is_atom(status),
    do: Atom.to_string(status) in @success_statuses

  defp success_status?(status) when is_binary(status),
    do: String.downcase(String.trim(status)) in @success_statuses

  defp success_status?(_), do: false

  # Minimal XML text-node escaping. `<` and `&` are the only two that can break
  # well-formedness; `>` is escaped too so a literal `]]>`-style sequence in
  # command output cannot be misread by a lenient parser.
  defp escape(v) do
    v
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  Surface a drain in the TUI: broadcast a `task_notification` SSE event on the
  session topic with a count + first-summary preview. Guarded; never raises.
  """
  @spec announce(String.t(), [notification()]) :: :ok
  def announce(session_id, notifications) when is_list(notifications) do
    summary =
      notifications
      |> Enum.map(&to_string(&1[:summary] || &1[:task_id] || ""))
      |> Enum.find("", &(&1 != ""))

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :task_notification,
         session_id: session_id,
         count: length(notifications),
         summary: String.slice(summary, 0, 200)
       }}
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp xml_value(v) when is_binary(v), do: v
  defp xml_value(v) when is_atom(v) or is_number(v), do: to_string(v)
  defp xml_value(v), do: inspect(v)
end
