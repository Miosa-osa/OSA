defmodule OptimalSystemAgent.Agent.Loop.CompactionAccountingTest do
  @moduledoc """
  What a compaction REPORTS must describe what it did.

  Reported live, three consecutive runs on grok-4.6:

      ✓ Compacted ~135.4k → ~6.7k tokens (976 messages folded) · 1m 16s
      ✓ Compacted ~4.1k → ~7.8k tokens (tool output pruned in place, …) · 1m 10s
      ✓ Compacted ~7.8k → ~7.5k tokens (1 messages folded) · instant

  Two defects in one line of arithmetic. `tokens_before` was measured over
  `older` (the slice being folded) while `tokens_after` was measured over the
  whole rebuilt conversation, so:

    * run 1's "after" (6.7k, whole) and run 2's "before" (4.1k, older only)
      described the same conversation with 2.6k of unexplained difference; and
    * run 2 could report GROWTH, because `recent` was counted on one side of
      the arrow and not the other.

  And underneath the mislabelling, a real floor was missing: the restore and
  reminder blocks are appended on success alone, so a fold on an already-small
  conversation can genuinely enlarge it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction

  setup do
    for table <- [:osa_compactor_state, :osa_files_read] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    :ok
  end

  defp filler, do: String.duplicate("lorem ipsum dolor sit amet consectetur ", 60)

  defp conversation(turns) do
    Enum.flat_map(1..turns, fn i ->
      [
        %{role: "user", content: "turn #{i}: #{filler()}"},
        %{role: "assistant", content: "reply #{i}: #{filler()}"}
      ]
    end)
  end

  defp capture_completed(sid, fun) do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
    result = fun.()

    completed =
      receive do
        {:osa_event, %{event: :compaction_completed} = p} -> p
      after
        2_000 -> nil
      end

    Phoenix.PubSub.unsubscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
    {result, completed}
  end

  test "tokens_before and tokens_after measure the same conversation" do
    sid = "acct-#{System.unique_integer([:positive])}"
    messages = conversation(8)

    {compacted, completed} =
      capture_completed(sid, fn -> ProactiveCompaction.compact(messages, sid) end)

    assert completed, "no compaction_completed event was broadcast"

    assert completed.tokens_before == Compactor.estimate_tokens(messages),
           "tokens_before (#{completed.tokens_before}) is not the size of the conversation " <>
             "that was handed in (#{Compactor.estimate_tokens(messages)}) — before and after " <>
             "are measuring different sets"

    assert completed.tokens_after == Compactor.estimate_tokens(compacted),
           "tokens_after (#{completed.tokens_after}) is not the size of the conversation " <>
             "that was returned (#{Compactor.estimate_tokens(compacted)})"
  end

  test "a reported compaction never grows the conversation" do
    sid = "grow-#{System.unique_integer([:positive])}"

    # Small enough that the advisory restore/reminder blocks can outweigh
    # whatever the fold reclaims — the shape that produced ~4.1k → ~7.8k.
    messages =
      Enum.flat_map(1..6, fn i ->
        [
          %{role: "user", content: "turn #{i}: #{String.duplicate("alpha beta ", 40)}"},
          %{role: "assistant", content: "reply #{i}: #{String.duplicate("gamma delta ", 40)}"}
        ]
      end)

    {compacted, completed} =
      capture_completed(sid, fn -> ProactiveCompaction.compact(messages, sid) end)

    if completed do
      assert completed.tokens_after <= completed.tokens_before,
             "a compaction reported success while growing the conversation: " <>
               "#{completed.tokens_before} → #{completed.tokens_after}"
    end

    assert Compactor.estimate_tokens(compacted) <= Compactor.estimate_tokens(messages),
           "the returned conversation is larger than the one handed in — the pass applied " <>
             "a result that made things worse"
  end

  test "when the fold cannot reduce, history is returned untouched" do
    sid = "floor-#{System.unique_integer([:positive])}"

    # Two turns: `keep_turns` (4) keeps everything, so `older` is empty and the
    # pass must decline without touching anything.
    messages = conversation(2)

    assert ProactiveCompaction.compact(messages, sid) == messages
  end
end
