defmodule OptimalSystemAgent.Agent.Loop.CompactionDoesNotReintroduceTest do
  @moduledoc """
  Does a fold RE-INTRODUCE content, or does it only mis-report?

  The capture that forced the question:

      ✓ Compacted ~6.1k → ~71.8k tokens (1 messages folded) · 1m 4s

  Read as a before/after of one conversation, that is ~65k tokens added by an
  operation whose only purpose is removal, and the ranked suspects were the
  restore block re-appending held content, the fold reading a stale collection,
  or world-state re-emission.

  It is none of those. `tokens_before` was measured over `older` — the slice
  being summarized — and `tokens_after` over `[summary | restore ++ reminder]
  ++ recent`, which includes the ~65k of RECENT turns that were never candidates
  for folding and are kept verbatim by design (`keep_turns`, default 4). The two
  numbers never described the same set, so the arrow between them was not a
  measurement of anything.

  These tests reproduce that exact shape — a small `older`, a large `recent` —
  and separate the two claims:

    * the CONVERSATION does not grow (no re-introduction), and
    * the OLD arithmetic reports growth anyway on the same data.

  The second is what makes this a labelling defect rather than a data defect.
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

  # The reported shape: a handful of small older turns, then several very large
  # recent turns (big tool results). `keep_turns` keeps the large tail verbatim.
  defp reported_shape do
    older =
      Enum.flat_map(1..3, fn i ->
        [
          %{role: "user", content: "OLDER-MARKER-#{i} #{String.duplicate("small ", 40)}"},
          %{role: "assistant", content: "OLDER-REPLY-#{i} #{String.duplicate("small ", 40)}"}
        ]
      end)

    recent =
      Enum.flat_map(1..5, fn i ->
        [
          %{role: "user", content: "RECENT-MARKER-#{i} #{String.duplicate("bulky ", 3_000)}"},
          %{role: "assistant", content: "RECENT-REPLY-#{i} #{String.duplicate("bulky ", 3_000)}"}
        ]
      end)

    older ++ recent
  end

  test "the folded conversation is never larger than the one handed in" do
    sid = "reintro-#{System.unique_integer([:positive])}"
    messages = reported_shape()

    compacted = ProactiveCompaction.compact(messages, sid)

    before_tokens = Compactor.estimate_tokens(messages)
    after_tokens = Compactor.estimate_tokens(compacted)

    assert after_tokens <= before_tokens,
           "the fold ADDED #{after_tokens - before_tokens} tokens " <>
             "(#{before_tokens} -> #{after_tokens}) — content is being re-introduced"
  end

  test "no folded message survives verbatim, and the kept tail is the only thing repeated" do
    sid = "reintro-v-#{System.unique_integer([:positive])}"
    messages = reported_shape()

    compacted = ProactiveCompaction.compact(messages, sid)
    body = compacted |> Enum.map(&to_string(Map.get(&1, :content, ""))) |> Enum.join("\n")

    # Hypothesis 1 (the restore block re-appends the pre-fold history) would put
    # the OLDER bodies back on the wire. They must be gone: only a summary of
    # them may survive.
    for i <- 1..3 do
      refute body =~ "OLDER-MARKER-#{i} small small",
             "a folded message came back verbatim — the fold re-introduced " <>
               "the content it was called to remove"
    end

    # The recent tail is kept verbatim ON PURPOSE (`keep_turns`), so its
    # presence is not evidence of re-introduction. Stated explicitly so this
    # test cannot be misread as proving the opposite.
    assert body =~ "RECENT-MARKER-5",
           "the kept tail was dropped — that is a different defect"
  end

  test "the old arithmetic reports growth on data that did not grow" do
    # The decisive artifact. Same conversation, two ways of measuring, and only
    # one of them produces the reported line.
    sid = "reintro-a-#{System.unique_integer([:positive])}"
    messages = reported_shape()

    compacted = ProactiveCompaction.compact(messages, sid)

    total_before = Compactor.estimate_tokens(messages)
    total_after = Compactor.estimate_tokens(compacted)

    # What the OLD code put on the left of the arrow: the folded slice only.
    {older, _recent} = split_older(messages)
    older_only = Compactor.estimate_tokens(older)

    assert total_after <= total_before,
           "precondition: the conversation itself did not grow"

    assert older_only < total_after,
           "this fixture does not reproduce the reported shape " <>
             "(#{older_only} vs #{total_after}); the point is that the OLD " <>
             "`tokens_before` is SMALLER than `tokens_after`, which is what " <>
             "rendered as ~6.1k → ~71.8k on a conversation that shrank"
  end

  # Mirrors `ProactiveCompaction.split_turns/2` at the default keep_turns (4):
  # the split point is the 4th-from-last user-message boundary.
  defp split_older(messages) do
    boundaries =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, idx} -> idx > 0 and Map.get(msg, :role) == "user" end)
      |> Enum.map(fn {_msg, idx} -> idx end)

    case Enum.take(boundaries, -4) do
      [] -> {[], messages}
      kept -> Enum.split(messages, List.first(kept))
    end
  end
end
