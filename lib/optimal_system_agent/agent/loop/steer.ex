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

  @doc """
  Steer directives currently in the in-memory ETS lane, WITHOUT a durable
  read. A steer queued during a live turn is always in ETS, so this is the
  cheap hot-path check (see `DurableInbox.live_count/2`).
  """
  @spec live_count(String.t()) :: non_neg_integer()
  def live_count(session_id) when is_binary(session_id) do
    DurableInbox.live_count(@table, session_id)
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

  # The minimal neutral marker prepended to a steer's text: it says only that
  # the message arrived while the model was working, nothing more. Deliberately
  # source-neutral ("received", not "the user sent") because this same builder
  # also carries the goal-tracker's own mid-turn nudges (which self-label with a
  # "[Goal tracker]" prefix); a marker asserting "the user sent this" would be a
  # lie on that path. For a real user steer the marker + the user's verbatim
  # text still reads as the user's own words with a timing note. See
  # `to_messages/1`.
  @marker "[Received while you were working]"

  @doc "The neutral mid-turn marker prepended to a steer (test seam)."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Build the message list injected into the conversation for a set of steer
  texts.

  ## Delivered as the user's own words

  A message the user sends mid-turn reaches the model as the USER'S OWN WORDS,
  as a `user`-role turn, with only a minimal neutral marker that it arrived
  while the model was working. There are NO imperatives, no "URGENT", and no
  instruction to drop the current plan — that earlier ~80-word framing was
  reported to confuse the model (it "adds extra instructions or context… it
  should have less than what it has"). The model decides what the message means
  for its work, exactly as it would for any user turn; the framing's only job is
  to say when the message arrived.

  ## Role and ordering

  `user` is valid after tool results on every provider path OSA uses: Anthropic
  takes user content after `tool_result` blocks (the interrupt marker in
  `ReactLoop.finalize_interrupt/2` already appends a `user` message right after
  tool results on this same path), and OpenAI-compat / Ollama both accept a
  `user` message after tool messages. So there is no system-role fallback to
  make here — the previous `system` role existed only to carry the imperative
  framing that is now gone.

  ## Identifying a steer

  A steer is identified INTERNALLY by the `steer: true` metadata key, not by any
  string in its prompt text — so tests and any future consumer key on structure,
  not on wording that is meant to stay minimal and may change. `format_messages`
  in every provider matches on `role`/`content` and ignores the extra key.
  """
  @spec to_messages([String.t()]) :: [map()]
  def to_messages(texts) when is_list(texts) do
    Enum.map(texts, fn text ->
      %{
        role: "user",
        content: "#{@marker}\n\n#{text}",
        steer: true
      }
    end)
  end
end
