defmodule OptimalSystemAgent.Agent.Loop.Steer do
  @moduledoc """
  Mid-turn steer queue (primitive #32 — TRUE mid-turn steer).

  A *steer* is a user directive folded into a RUNNING agent turn at its next
  ReAct step boundary. Unlike a new turn (`process_message`) or a front-of-queue
  message (runs at the *next* turn), a steer lets the agent adapt WITHOUT the
  caller cancelling the turn and losing in-flight work.

  ## Why ETS and not a GenServer message

  The `Loop` process is blocked inside `handle_call/3` for the whole duration of
  a turn (`ReactLoop.run/1` runs synchronously there), so its mailbox is not
  serviced — a `cast`/`call` would only be handled *after* the turn ends, which
  defeats "mid-turn". ETS reads/writes work concurrently regardless of the
  process being busy, so a steer queued from the HTTP request process is visible
  to the running loop between steps. This mirrors exactly why `Loop.cancel/1`
  uses the `:osa_cancel_flags` ETS table.

  ## Storage

  Rows are `{{session_id, seq}, text}` in the `:osa_steer_queue` `:ordered_set`,
  where `seq` is a strictly-increasing monotonic integer. Production consumers
  reserve directives in FIFO order and acknowledge them only after persisting
  their incorporation into the session transcript.
  """
  require Logger

  alias OptimalSystemAgent.Agent.DurableInbox

  @table :osa_steer_queue

  @doc """
  Enqueue a steer directive for `session_id`.

  Concurrent-safe and non-blocking; returns `:ok` even if the table is missing
  (feature simply degrades to a no-op rather than crashing the caller).
  """
  @spec queue(String.t(), String.t()) :: :ok | {:error, term()}
  def queue(session_id, text) when is_binary(session_id) and is_binary(text) do
    DurableInbox.append(@table, session_id, :steers, %{text: text})
  rescue
    ArgumentError ->
      Logger.warning("[steer] queue table missing — steer dropped for #{session_id}")
      :ok
  end

  @doc """
  Remove and return all queued steer directives for `session_id`, oldest first.
  Returns `[]` when nothing is queued (or the table is unavailable).
  """
  @spec drain(String.t()) :: [String.t()]
  def drain(session_id) when is_binary(session_id) do
    DurableInbox.drain(@table, session_id, :steers)
    |> Enum.map(&(&1[:text] || &1["text"]))
    |> Enum.filter(&is_binary/1)
  rescue
    ArgumentError -> []
  end

  @doc "Number of steer directives currently queued for `session_id`."
  @spec count(String.t()) :: non_neg_integer()
  def count(session_id) when is_binary(session_id) do
    DurableInbox.count(@table, session_id, :steers)
  rescue
    ArgumentError -> 0
  end

  @doc false
  def checkout(session_id) do
    case DurableInbox.checkout(@table, session_id, :steers) do
      :empty ->
        :empty

      {receipt, payloads} ->
        texts = payloads |> Enum.map(&(&1[:text] || &1["text"])) |> Enum.filter(&is_binary/1)
        {receipt, texts}
    end
  end

  @doc false
  def acknowledge(session_id, receipt) do
    DurableInbox.acknowledge(@table, session_id, :steers, receipt)
  end

  @doc false
  def release(session_id, receipt), do: DurableInbox.release(@table, session_id, receipt)

  @doc """
  Build the message list injected into the conversation for a set of steer
  texts. A steer is surfaced as a `system` directive (consistent with every
  other mid-turn injection in `ReactLoop`, which avoids provider role-alternation
  issues) but is clearly labelled as coming from the user.

  ## Why the framing is imperative

  The earlier wording ("adapt your current work to incorporate this now, without
  discarding progress already made") was too soft: a model with momentum on a
  plan read "without discarding progress" as licence to FINISH the whole plan
  first and only acknowledge the steer at the very end - reported as "it told me
  at the end, it didn't take what I said into consideration as it was working".
  The framing now names and forbids that exact failure so the model treats the
  steer as an interrupt to act on BEFORE its next action, not a closing note.
  "User steer" is preserved as a stable, testable marker.
  """
  @spec to_messages([String.t()]) :: [map()]
  def to_messages(texts) when is_list(texts) do
    Enum.map(texts, fn text ->
      %{
        role: "system",
        content:
          "[URGENT User steer - a mid-turn course correction the user sent WHILE you are " <>
            "working. Treat it as the user interrupting you right now. Before your very next " <>
            "action, act on it: change your current plan to satisfy it, carrying forward the " <>
            "progress you have already made. Do NOT finish your existing plan first and only " <>
            "mention this at the end - that is the exact failure this directive exists to " <>
            "prevent. If it changes what you should be doing, change course immediately.]: " <>
            text
      }
    end)
  end
end
