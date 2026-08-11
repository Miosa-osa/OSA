defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Discipline do
  @moduledoc """
  Rate discipline for the subagent voice.

  ## Why this module exists

  The pipe was never the problem. `send_message` already broadcasts, the TUI
  already renders `› Message from @x: …`, and nothing strips the tool from a
  subagent. What was missing is the thing that makes an interruption channel
  worth having: a reason to believe that when it fires, it matters.

  A subagent that speaks every thirty seconds is strictly worse than one that
  never speaks. The silent one costs nothing; the chatty one trains the user to
  skim past the channel, and the cost of that is paid by the one message that
  was actually important. So the budget is not a safety valve bolted on after
  the fact — it IS the feature.

  ## The four rules

    * **Budget** — `Constants.max_messages_per_run/0` (2) per run, hard. The
      third attempt is REFUSED WITH A REASON THE MODEL CAN READ, not silently
      dropped: a model that thinks it spoke and did not will keep trying.
    * **Spacing** — `Constants.min_spacing_ms/0` between two messages from the
      same sender. Inside the budget, two messages back to back still read as a
      stream rather than as two separate things worth knowing.
    * **Warm-up** — `Constants.warmup_ms/0` of silence at the start of a run.
      Nothing a subagent "discovers" in its first few tool calls is news; it is
      reading the files it was told to read.
    * **Truncation** — `Constants.max_message_chars/0`, truncated and NEVER
      rejected. An over-long message is a message with its lead buried at the
      front; rejecting it would throw the lead away too and burn one of only
      two chances to say anything.

  ## Who it applies to

  Only to senders that ARE a subagent run — i.e. that have a `RunStore` row.
  A top-level session messaging a teammate is the user's own instruction
  channel, and rationing or truncating that would be destructive. Absence of a
  run row is therefore a pass, not a failure.
  """

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Tools.Builtins.SendMessage.Constants

  @type verdict :: :ok | {:refused, String.t()}

  @doc """
  Decide whether `sender_id` may speak now, and record the send if so.

  Returns `:ok` (the send is charged against the budget) or
  `{:refused, reason}` where `reason` is written FOR THE MODEL — it names the
  rule, and says what to do instead.

  `now_ms` is injectable so the time-window rules are testable without sleeping
  through a 60s window.
  """
  @spec check(String.t() | nil, integer()) :: verdict()
  def check(sender_id, now_ms \\ nil)

  def check(sender_id, now_ms) when is_binary(sender_id) do
    now_ms = now_ms || System.system_time(:millisecond)

    case run_start_ms(sender_id) do
      # Not a subagent run: the user's own channel, ungoverned.
      nil -> :ok
      started_ms -> govern(sender_id, started_ms, now_ms)
    end
  end

  def check(_sender_id, _now_ms), do: :ok

  # Order is deliberate: the reason the model is shown should be the one that
  # will still be true longest. Warm-up expires in seconds, the budget never
  # refills, so a sender that is both inside the warm-up AND over budget is
  # told about the budget only once the warm-up is irrelevant.
  defp govern(sender_id, started_ms, now_ms) do
    {count, last_ms} = usage(sender_id)

    cond do
      now_ms - started_ms < Constants.warmup_ms() ->
        {:refused,
         "Not sent: you are #{div(now_ms - started_ms, 1000)}s into this run and the " <>
           "first #{div(Constants.warmup_ms(), 1000)}s are silent by design. Nothing found " <>
           "in your first few tool calls is news to the user — keep working, and save this " <>
           "for your report unless it is still worth interrupting for later."}

      count >= Constants.max_messages_per_run() ->
        {:refused,
         "Not sent: you have used your #{Constants.max_messages_per_run()} messages for " <>
           "this run. Save the rest for your report — it is read in full, and everything " <>
           "you have left to say belongs there."}

      is_integer(last_ms) and now_ms - last_ms < Constants.min_spacing_ms() ->
        {:refused,
         "Not sent: you sent a message #{div(now_ms - last_ms, 1000)}s ago and messages " <>
           "are spaced at least #{div(Constants.min_spacing_ms(), 1000)}s apart. Two " <>
           "messages in a row read as a stream, not as two things worth knowing. Keep " <>
           "working; this can go in your report."}

      true ->
        record(sender_id, count, now_ms)
        :ok
    end
  end

  @doc """
  Cap a message at `Constants.max_message_chars/0`.

  Truncation, not rejection — see the module doc. The ellipsis is explicit so
  the user can tell a cut message from a terse one.
  """
  @spec truncate(String.t()) :: String.t()
  def truncate(message) when is_binary(message) do
    max = Constants.max_message_chars()

    if String.length(message) > max do
      String.slice(message, 0, max - 1) <> "…"
    else
      message
    end
  end

  def truncate(message), do: message

  @doc """
  Cap a message only when its sender is governed by the discipline.

  A top-level session sending `send_message` is the USER's instruction channel
  to a teammate; clipping that at 200 characters would destroy real content.
  The cap exists for the interruption channel, so it applies exactly where the
  budget does.
  """
  @spec truncate(String.t(), String.t() | nil) :: String.t()
  def truncate(message, sender_id) do
    if governed?(sender_id), do: truncate(message), else: message
  end

  @doc """
  Whether `sender_id` is a subagent run, and therefore subject to the budget,
  the spacing, the warm-up and the length cap.
  """
  @spec governed?(String.t() | nil) :: boolean()
  def governed?(sender_id) when is_binary(sender_id), do: run_start_ms(sender_id) != nil
  def governed?(_), do: false

  @doc "Messages already spent by `sender_id` in this run."
  @spec sent_count(String.t()) :: non_neg_integer()
  def sent_count(sender_id) when is_binary(sender_id) do
    {count, _last} = usage(sender_id)
    count
  end

  def sent_count(_), do: 0

  @doc """
  Forget `sender_id`'s budget. Called when a run is torn down, and by tests.
  """
  @spec reset(String.t()) :: :ok
  def reset(sender_id) when is_binary(sender_id) do
    ensure_table()
    :ets.delete(Constants.budget_table(), sender_id)
    :ok
  rescue
    _ -> :ok
  end

  def reset(_), do: :ok

  # --- Private -----------------------------------------------------------

  # Wall-clock ms at which this sender's run started, or nil when the sender is
  # not a subagent run at all.
  defp run_start_ms(sender_id) do
    case RunStore.get(sender_id) do
      %{started_at: %DateTime{} = at} -> DateTime.to_unix(at, :millisecond)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp usage(sender_id) do
    ensure_table()

    case :ets.lookup(Constants.budget_table(), sender_id) do
      [{^sender_id, count, last_ms}] -> {count, last_ms}
      _ -> {0, nil}
    end
  rescue
    _ -> {0, nil}
  end

  defp record(sender_id, count, now_ms) do
    ensure_table()
    :ets.insert(Constants.budget_table(), {sender_id, count + 1, now_ms})
    :ok
  rescue
    _ -> :ok
  end

  # `:ets.new/2` raises when the named table already exists, and the table is
  # created lazily by whichever caller arrives first, so the raise is the normal
  # path under concurrency rather than an error.
  defp ensure_table do
    table = Constants.budget_table()

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table, {:write_concurrency, true}])
    end

    table
  rescue
    ArgumentError -> Constants.budget_table()
  end
end
