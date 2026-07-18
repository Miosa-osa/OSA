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

  @doc "Render one notification as its `<task-notification>` XML block."
  @spec to_xml(notification()) :: String.t()
  def to_xml(n) when is_map(n) do
    fields =
      [
        {"task-id", n[:task_id]},
        {"tool-use-id", n[:tool_use_id]},
        {"status", n[:status]},
        {"output-file", n[:output_file]},
        {"summary", n[:summary]},
        {"usage", n[:usage]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, v} -> "  <#{k}>#{xml_value(v)}</#{k}>" end)
      |> Enum.join("\n")

    "<task-notification>\n" <>
      fields <>
      "\n</task-notification>\n" <>
      "[A background task finished. React to this result now if it affects your " <>
      "current work or the user's request; the full output is in the output-file " <>
      "(readable with the read tool). Do not poll for this task again.]"
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
