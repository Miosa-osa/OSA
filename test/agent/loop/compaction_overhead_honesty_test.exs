defmodule OptimalSystemAgent.Agent.Loop.CompactionOverheadHonestyTest do
  @moduledoc """
  Regression coverage for the "/compact meter jumps on the very next request"
  incident (v1.0.204, deepseek-v4.1-flash:cloud, 200K operative window):

      [ctx] estimated=139741 util=69.9%
      [proactive_compaction] folded 205 older messages into 1 summary
        (~89383 -> ~25178 tokens; kept 61 recent verbatim, injections=full)
      [ctx] estimated=25178 util=12.6%
      LLM call completed (61667 input tokens) -> [ctx] estimated=63661 util=31.8%

  Two independent defects produced that log:

    1. `tokens_before`/`tokens_after` (and the post-fold `last_input_tokens`
       refresh) were computed with `Agent.Compactor.estimate_tokens/1` alone -
       a MESSAGE-ONLY heuristic that omits the system prompt and tool
       schemas. `Agent.Compactor.total_and_overhead/2` is the fix: the real
       total (provider-reported when available) minus the message-only
       estimate is the "overhead" that must be re-applied on BOTH sides of a
       compaction pass so the reported/refreshed total never drops it.

    2. The verbatim "recent" tail was selected by a fixed TURN COUNT
       (`proactive_compaction_keep_turns`, default 4), so a handful of
       tool-heavy turns could smuggle tens of thousands of tokens of "kept
       verbatim" history past the fold - which is how a fold landed at 31.8%
       of a 200k window instead of comfortably under the 30% target implied
       by the reserve math. `Agent.Compactor.turn_tail_start/2` (a token
       BUDGET, tool-pair safe) replaces the count when a real context window
       is known.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction

  @operative_window 200_000

  setup do
    for table <- [:osa_compactor_state, :osa_files_read] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    :ok
  end

  defp sid, do: "overhead-#{System.unique_integer([:positive])}"

  # Ordinary filler turn - sized like `compaction_accounting_test.exs`'s
  # `conversation/1` so `older_tokens` comfortably clears
  # `proactive_compaction_min_older_tokens` (400) and a fold actually runs.
  defp filler, do: String.duplicate("lorem ipsum dolor sit amet consectetur ", 60)

  defp small_turn(i) do
    [
      %{role: "user", content: "turn #{i}: #{filler()}"},
      %{role: "assistant", content: "reply #{i}: #{filler()}"}
    ]
  end

  # A tool-heavy turn. `String.duplicate("x", bytes)` has no whitespace, so
  # `Compactor.estimate_tokens/1`'s word+punctuation heuristic loses to its own
  # `bytes / 4` floor - giving a precisely controllable token cost per turn
  # instead of an approximate lorem-ipsum word count.
  defp heavy_tool_turn(n, bytes) do
    id = "call_#{n}"

    [
      %{role: "user", content: "run task #{n}"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: id, name: "shell_execute", arguments: %{"cmd" => "task #{n}"}}]
      },
      %{
        role: "tool",
        tool_call_id: id,
        name: "shell_execute",
        content: String.duplicate("x", bytes)
      },
      %{role: "assistant", content: "done with task #{n}"}
    ]
  end

  defp heavy_conversation(turns, bytes_per_turn),
    do: Enum.flat_map(1..turns, &heavy_tool_turn(&1, bytes_per_turn))

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

  # No orphaned tool result anywhere: every `role: "tool"` message's
  # `tool_call_id` must be satisfied by a PRECEDING assistant `tool_calls`
  # entry with the same id, in the SAME list.
  defp assert_no_orphan_tool_results(messages) do
    {_seen, orphans} =
      Enum.reduce(messages, {MapSet.new(), []}, fn msg, {seen, orphans} ->
        case Map.get(msg, :tool_calls) do
          calls when is_list(calls) and calls != [] ->
            ids = calls |> Enum.map(&Map.get(&1, :id)) |> Enum.reject(&is_nil/1)
            {Enum.reduce(ids, seen, &MapSet.put(&2, &1)), orphans}

          _ ->
            case Map.get(msg, :role) do
              "tool" ->
                tcid = Map.get(msg, :tool_call_id)

                if is_nil(tcid) or MapSet.member?(seen, tcid) do
                  {seen, orphans}
                else
                  {seen, [tcid | orphans]}
                end

              _ ->
                {seen, orphans}
            end
        end
      end)

    assert orphans == [],
           "orphaned tool_call_id(s) with no preceding tool_calls entry: #{inspect(orphans)}"
  end

  # ---------------------------------------------------------------------------
  # 1. Overhead accounting: the reported/refreshed total must include it
  # ---------------------------------------------------------------------------

  describe "known_tokens / overhead accounting" do
    test "tokens_before honours the real provider-reported total, not the message-only estimate" do
      sid = sid()
      messages = Enum.flat_map(1..8, &small_turn/1)

      # A REAL total that is (deliberately) far bigger than the message-only
      # estimate - standing in for "system prompt + tool schemas the message
      # list cannot see", exactly like a real `state.last_input_tokens` does.
      real_total = Compactor.estimate_tokens(messages) + 40_000

      {compacted, completed} =
        capture_completed(sid, fn ->
          ProactiveCompaction.compact(messages, sid, nil, :auto, known_tokens: real_total)
        end)

      assert completed, "no compaction_completed event was broadcast"
      assert completed.tokens_before == real_total

      overhead = real_total - Compactor.estimate_tokens(messages)

      assert completed.tokens_after == overhead + Compactor.estimate_tokens(compacted),
             "tokens_after dropped the overhead instead of carrying it across the fold"

      # The specific regression: tokens_after must NOT collapse to the
      # message-only estimate (the old bug, byte-for-byte).
      refute completed.tokens_after == Compactor.estimate_tokens(compacted),
             "tokens_after silently dropped the #{overhead}-token overhead - this is the " <>
               "exact defect that made a /compact notice announce a total lower than what " <>
               "the very next request actually sent"
    end

    test "omitting known_tokens keeps the old message-only behaviour (no regression)" do
      sid = sid()
      messages = Enum.flat_map(1..8, &small_turn/1)

      {compacted, completed} =
        capture_completed(sid, fn -> ProactiveCompaction.compact(messages, sid) end)

      assert completed
      assert completed.tokens_before == Compactor.estimate_tokens(messages)
      assert completed.tokens_after == Compactor.estimate_tokens(compacted)
    end

    test "Compactor.total_and_overhead/2 is the single formula both sides of a pass share" do
      messages = Enum.flat_map(1..4, &small_turn/1)
      estimate = Compactor.estimate_tokens(messages)

      assert Compactor.total_and_overhead(messages, nil) == {estimate, 0}
      assert Compactor.total_and_overhead(messages, 0) == {estimate, 0}

      assert Compactor.total_and_overhead(messages, estimate + 12_345) ==
               {estimate + 12_345, 12_345}

      # A known_tokens smaller than the estimate (a stale/short-lived report)
      # is still honoured as the total when positive - it never yields a
      # NEGATIVE overhead.
      assert Compactor.total_and_overhead(messages, 1) == {1, 0}
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Budget-based recent tail: lands well under 30% of the operative window
  # ---------------------------------------------------------------------------

  describe "token-budgeted recent tail (build-plan item 2 + 4)" do
    test "a tool-heavy fold lands well under 30% of a 200k operative window when given the real context_window" do
      # 6 turns, ~18k tokens each (72,000 "x" bytes / 4) of pure tool output -
      # the shape that produced "kept 61 recent verbatim" in the incident:
      # a handful of tool-heavy turns, not a long low-content conversation.
      messages = heavy_conversation(6, 72_000)

      old_sid = sid()
      new_sid = sid()

      # OLD behaviour: no context_window given, falls back to the fixed
      # `proactive_compaction_keep_turns` (4) - kept for backward
      # compatibility, and reproduced here to show what it does NOT fix.
      old_compacted = ProactiveCompaction.compact(messages, old_sid)
      old_total = Compactor.estimate_tokens(old_compacted)
      old_pct = old_total / @operative_window

      # NEW behaviour: a real context window is known, so the recent tail is
      # TOKEN-BUDGETED (a share of the operative window) instead of a fixed
      # turn count.
      new_compacted =
        ProactiveCompaction.compact(messages, new_sid, nil, :auto,
          context_window: @operative_window
        )

      new_total = Compactor.estimate_tokens(new_compacted)
      new_pct = new_total / @operative_window

      # Both paths benefit from the stale-tool-result clearing wired into
      # `recent` (item 2), which is why `old_pct` alone does not reliably
      # reproduce the incident's 31.8% on this fixture. Logged for context
      # (visible in a failure message), not asserted on, so this test does
      # not depend on that interaction.
      _ = old_pct

      assert new_pct < 0.30,
             "budgeted fold landed at #{Float.round(new_pct * 100, 1)}% of the operative " <>
               "window - expected comfortably under 30%"

      assert new_total < old_total,
             "the token-budgeted tail (#{new_total} tokens) must be smaller than the fixed " <>
               "turn-count tail (#{old_total} tokens) for a tool-heavy session"

      assert_no_orphan_tool_results(old_compacted)
      assert_no_orphan_tool_results(new_compacted)
    end

    test "turn_tail_start/2 never starts the kept tail on an orphaned tool result" do
      messages = heavy_conversation(6, 72_000)

      # Swept across budgets that land the naive backward split at every
      # point inside a turn - including budgets sized to fit a tool result
      # but not the assistant call that produced it, which is exactly the
      # shape `CompactionSafety.safe_split_index/2`'s forward-snap exists to
      # correct.
      for budget <- [100, 5_000, 18_020, 30_000, 50_000, 90_000] do
        split = Compactor.turn_tail_start(messages, budget)
        tail = Enum.drop(messages, split)
        assert_no_orphan_tool_results(tail)

        if split < length(messages) do
          refute Map.get(Enum.at(messages, split), :role) == "tool",
                 "budget=#{budget} produced a kept tail starting on an orphaned tool result"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Stale tool-result clearing inside the kept tail (build-plan item 2)
  # ---------------------------------------------------------------------------

  describe "stale tool-result clearing inside the recent tail" do
    test "everything but the last two turns of the kept tail is stubbed, not just summarized" do
      messages = heavy_conversation(6, 72_000)
      session = sid()

      prev = Application.get_env(:optimal_system_agent, :proactive_compaction_recent_tokens)
      # Wide enough to keep turns 4, 5 and 6 (3 full turns) verbatim-selected,
      # so "everything but the last couple of turns" has a turn to act on.
      Application.put_env(:optimal_system_agent, :proactive_compaction_recent_tokens, 55_000)

      on_exit(fn ->
        case prev do
          nil ->
            Application.delete_env(:optimal_system_agent, :proactive_compaction_recent_tokens)

          v ->
            Application.put_env(:optimal_system_agent, :proactive_compaction_recent_tokens, v)
        end
      end)

      compacted =
        ProactiveCompaction.compact(messages, session, nil, :auto,
          context_window: @operative_window
        )

      tool_contents =
        compacted
        |> Enum.filter(&(Map.get(&1, :role) == "tool"))
        |> Enum.map(&Map.get(&1, :content))

      # Matches `ContextReduce`'s own `@stub_marker` prefix (deliberately not
      # the full marker string here, to stay independent of its exact
      # punctuation).
      assert Enum.any?(tool_contents, &String.starts_with?(&1, "[Tool result cleared")),
             "expected at least one stale tool result inside the kept tail to be stubbed"

      assert Enum.any?(tool_contents, &String.starts_with?(&1, "xxxx")),
             "expected the last couple of turns' tool results to survive verbatim"

      assert_no_orphan_tool_results(compacted)
    end
  end
end
