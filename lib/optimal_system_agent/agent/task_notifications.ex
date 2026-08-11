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
  `:ordered_set` (FIFO drain, destructive → exactly-once). The
  `:osa_task_notified` set holds per-task check-and-set flags so a
  `bash_output` poll and the completion broadcast racing yield exactly ONE
  notification per task.
  """
  require Logger

  @table :osa_task_notifications
  @notified_table :osa_task_notified

  @type notification :: map()

  @doc "Enqueue a task notification for `session_id`. Never raises."
  @spec queue(String.t(), notification()) :: :ok
  def queue(session_id, notification) when is_binary(session_id) and is_map(notification) do
    seq = :erlang.unique_integer([:monotonic, :positive])
    :ets.insert(@table, {{session_id, seq}, notification})
    :ok
  rescue
    ArgumentError ->
      Logger.warning("[task-notif] queue table missing — notification dropped for #{session_id}")
      :ok
  end

  @doc "Remove and return all queued notifications for `session_id`, oldest first."
  @spec drain(String.t()) :: [notification()]
  def drain(session_id) when is_binary(session_id) do
    match = [{{{session_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    case :ets.select(@table, match) do
      [] ->
        []

      rows ->
        rows
        |> Enum.sort_by(fn {seq, _n} -> seq end)
        |> Enum.map(fn {seq, notif} ->
          :ets.delete(@table, {session_id, seq})
          notif
        end)
    end
  rescue
    ArgumentError -> []
  end

  @doc "Number of notifications currently queued for `session_id`."
  @spec count(String.t()) :: non_neg_integer()
  def count(session_id) when is_binary(session_id) do
    :ets.select_count(@table, [{{{session_id, :_}, :_}, [], [true]}])
  rescue
    ArgumentError -> 0
  end

  @doc "Whether any notifications are pending for `session_id`."
  @spec pending?(String.t()) :: boolean()
  def pending?(session_id), do: count(session_id) > 0

  @doc """
  Check-and-set the per-task \"notified\" flag. Returns `true` exactly once per
  `task_id` — the winner is the only path allowed to notify (completion
  broadcast vs a `bash_output` poll that already saw the terminal status).
  """
  @spec mark_notified(String.t()) :: boolean()
  def mark_notified(task_id) when is_binary(task_id) do
    :ets.insert_new(@notified_table, {task_id, System.system_time(:millisecond)})
  rescue
    ArgumentError -> true
  end

  @doc """
  Build the injected message list: one system message per notification,
  wrapping a `<task-notification>` XML block (CC parity).
  """
  @spec to_messages([notification()]) :: [map()]
  def to_messages(notifications) when is_list(notifications) do
    Enum.map(notifications, fn n -> %{role: "system", content: to_xml(n)} end)
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
      completion_instruction()
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

  @doc "The trailing instruction appended to every `<task-notification>` block."
  @spec completion_instruction() :: String.t()
  def completion_instruction, do: @completion_instruction

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
