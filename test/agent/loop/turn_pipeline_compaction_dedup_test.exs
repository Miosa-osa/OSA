defmodule OptimalSystemAgent.Agent.Loop.TurnPipelineCompactionDedupTest do
  @moduledoc """
  Regression test for finding #8: `TurnPipeline.prepare_turn/3` and
  `ReactLoop.do_iteration/1` (iteration 0 of a turn) both decide whether to
  compact off the SAME `:last_input_tokens` field. That field is otherwise
  only refreshed by `Loop.Accounting` AFTER a provider round-trip, so without
  a refresh in between, both compactors see the identical pre-compaction
  count on iteration 0 and both fire — two LLM summarization round-trips
  back to back.

  `TurnPipeline.compact_and_refresh_tokens/1` is the fix: it re-estimates
  `:last_input_tokens` from the ALREADY-COMPACTED history immediately after
  compaction runs, so a second compaction-decision check later in the same
  iteration correctly sees the shrunk size and skips.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.{CompactionThresholds, ProactiveCompaction, TurnPipeline}

  @cw 200_000

  setup do
    for table <- [:osa_compactor_state, :osa_files_read] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    original_max = Application.get_env(:optimal_system_agent, :max_context_tokens)
    original_warn = Application.get_env(:optimal_system_agent, :compaction_warn)

    on_exit(fn ->
      if original_max,
        do: Application.put_env(:optimal_system_agent, :max_context_tokens, original_max),
        else: Application.delete_env(:optimal_system_agent, :max_context_tokens)

      if original_warn,
        do: Application.put_env(:optimal_system_agent, :compaction_warn, original_warn),
        else: Application.delete_env(:optimal_system_agent, :compaction_warn)
    end)

    :ok
  end

  defp big_messages do
    filler = String.duplicate("lorem ipsum dolor sit amet consectetur adipiscing elit ", 300)

    Enum.flat_map(1..40, fn i ->
      [
        %{role: "user", content: "turn #{i} question: #{filler}"},
        %{role: "assistant", content: "turn #{i} answer: #{filler}"}
      ]
    end)
  end

  test "refreshes last_input_tokens to the POST-compaction size, not the stale pre-compaction one" do
    messages = big_messages()
    pre_compaction_estimate = Compactor.estimate_tokens(messages)

    # Force the Compactor to actually run against this history.
    Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)

    Application.put_env(
      :optimal_system_agent,
      :max_context_tokens,
      div(pre_compaction_estimate, 2)
    )

    sid = "dedup-#{System.unique_integer([:positive])}"
    state = %{messages: messages, session_id: sid, last_input_tokens: pre_compaction_estimate}

    result = TurnPipeline.compact_and_refresh_tokens(state)

    assert length(result.messages) < length(messages), "compaction should have shrunk history"

    assert result.last_input_tokens == Compactor.estimate_tokens(result.messages),
           "last_input_tokens must be refreshed to match the POST-compaction history"

    assert result.last_input_tokens < pre_compaction_estimate,
           "the refreshed count must reflect the shrunk history, not the stale pre-compaction one"
  end

  test "a second compaction-decision check in the SAME iteration correctly skips after the refresh (finding #8)" do
    messages = big_messages()
    pre_compaction_estimate = Compactor.estimate_tokens(messages)

    Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)

    Application.put_env(
      :optimal_system_agent,
      :max_context_tokens,
      div(pre_compaction_estimate, 2)
    )

    sid = "dedup-#{System.unique_integer([:positive])}"
    state = %{messages: messages, session_id: sid, last_input_tokens: pre_compaction_estimate}

    result = TurnPipeline.compact_and_refresh_tokens(state)

    # Pick a context window where the ORIGINAL (stale) token count trips
    # ProactiveCompaction.should_compact?/2 — reproducing the regression: the
    # OLD stale-token bug would have this second check ALSO fire, running a
    # second LLM summarization pass on the very first iteration.
    at = CompactionThresholds.compact_at(@cw)

    assert pre_compaction_estimate >= at,
           "test fixture must make the STALE pre-compaction count exceed compact_at " <>
             "(#{pre_compaction_estimate} vs #{at}) to reproduce the regression scenario"

    # Sanity: using the STALE (un-refreshed) count would have double-fired.
    stale_state = %{result | last_input_tokens: pre_compaction_estimate}
    assert ProactiveCompaction.should_compact?(stale_state, @cw)

    # With the fix, the refreshed (post-compaction) count no longer trips it.
    refute ProactiveCompaction.should_compact?(result, @cw),
           "the second compaction-decision check must skip once last_input_tokens reflects " <>
             "the already-shrunk history"
  end

  test "no-op when compaction does not actually shrink history — last_input_tokens is left untouched" do
    messages = [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]
    sid = "dedup-noop-#{System.unique_integer([:positive])}"

    # Default thresholds: this tiny history is nowhere near max_context_tokens.
    Application.delete_env(:optimal_system_agent, :max_context_tokens)

    state = %{messages: messages, session_id: sid, last_input_tokens: 123}

    result = TurnPipeline.compact_and_refresh_tokens(state)

    assert result.messages == messages
    assert result.last_input_tokens == 123
  end
end
