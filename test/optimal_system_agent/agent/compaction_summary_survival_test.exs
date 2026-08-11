defmodule OptimalSystemAgent.Agent.CompactionSummarySurvivalTest do
  @moduledoc """
  The compaction pipeline used to destroy, in the same run, the summary it had
  just paid an LLM call to produce.

  `apply_step(:compress_cold, ...)` prepends the summary at index 0 of the
  annotated (non-system) list with an importance of 2.0. `pipeline_step/4` then
  runs `:emergency_truncate` whenever the result is still over budget, and that
  step drops `Enum.slice(annotated, 0, split)` — purely positional. Index 0 is
  the summary. The importance annotation was never consulted.

  Because the pipeline's return value replaces `state.messages`, the entire cold
  span survived nowhere but `<id>.updates.jsonl`: real user data, gone. All that
  reached the model was the `[Context truncated ...]` topic notice.

  These tests are written against the OBSERVABLE output of `maybe_compact/1`.
  """
  # async: false — mutates global :max_context_tokens / severity env that lib
  # code reads through Application.get_env.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor

  setup do
    # The cold summarizer persists its last structured summary in the shared
    # :osa_compactor_state ETS table; a stale entry perturbs these assertions.
    clear = fn ->
      try do
        :ets.match_delete(:osa_compactor_state, {{:previous_summary, :_}, :_})
        :ets.match_delete(:osa_compactor_state, {{:last_summary_at, :_}, :_})
      rescue
        ArgumentError -> :ok
      end
    end

    clear.()

    keys = [
      :max_context_tokens,
      :compaction_warn,
      :compaction_aggressive,
      :compaction_emergency
    ]

    prev = Enum.map(keys, &{&1, Application.get_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      clear.()

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:optimal_system_agent, k)
        {k, v} -> Application.put_env(:optimal_system_agent, k, v)
      end)
    end)

    :ok
  end

  # A conversation long enough that compress_cold has a real cold span AND the
  # result is still over budget afterwards, so emergency_truncate also runs.
  defp long_conversation(n) do
    filler = String.duplicate("substantive content that resists compression ", 12)

    Enum.flat_map(1..n, fn i ->
      [
        %{role: "user", content: "User turn #{i}: #{filler}"},
        %{role: "assistant", content: "Assistant turn #{i}: #{filler}"}
      ]
    end)
  end

  # Force the emergency tier with a window small enough that no single step can
  # get under target — guaranteeing the pipeline runs all the way through
  # compress_cold and then emergency_truncate.
  defp force_emergency(messages) do
    est = Compactor.estimate_tokens(messages)
    Application.put_env(:optimal_system_agent, :max_context_tokens, div(est, 20))
    Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)
    Application.put_env(:optimal_system_agent, :compaction_aggressive, 0.0)
    Application.put_env(:optimal_system_agent, :compaction_emergency, 0.0)
  end

  defp contents(messages), do: Enum.map(messages, &to_string(Map.get(&1, :content, "")))

  defp has_summary?(messages),
    do: Enum.any?(contents(messages), &String.contains?(&1, "[Context Summary]"))

  defp has_truncation_notice?(messages),
    do: Enum.any?(contents(messages), &String.contains?(&1, "[Context truncated"))

  describe "compress_cold -> emergency_truncate in one pipeline run" do
    test "the cold-zone summary survives the emergency truncate that follows it" do
      messages = long_conversation(120)
      force_emergency(messages)

      result = Compactor.maybe_compact(messages)

      # Sanity: the run really did reach the last step, otherwise this test
      # would pass vacuously without ever exercising the defect.
      assert has_truncation_notice?(result),
             "fixture must be aggressive enough to reach :emergency_truncate"

      assert length(result) < length(messages), "the pipeline must actually have compacted"

      # The defect: this summary was produced by :compress_cold and then dropped
      # at index 0 by :emergency_truncate in the same run.
      assert has_summary?(result),
             "the cold-zone summary was destroyed by the emergency truncate that " <>
               "ran after it — the summarized span now exists nowhere in context. " <>
               "Got: #{inspect(Enum.map(result, &String.slice(to_string(Map.get(&1, :content, "")), 0, 60)))}"
    end

    test "the surviving summary still carries the summarized content" do
      messages = long_conversation(120)
      force_emergency(messages)

      result = Compactor.maybe_compact(messages)

      summary =
        Enum.find(contents(result), &String.contains?(&1, "[Context Summary]"))

      assert is_binary(summary)

      # With compactor_llm_enabled: false the stub summary names how many
      # messages it absorbed; that count must be non-trivial, i.e. the summary
      # that survived is the one covering the cold span.
      assert summary =~ ~r/Key facts from (\d+) messages/

      [_, count] = Regex.run(~r/Key facts from (\d+) messages/, summary)
      assert String.to_integer(count) > 10
    end

    test "the summary is not duplicated by surviving the truncate" do
      messages = long_conversation(120)
      force_emergency(messages)

      result = Compactor.maybe_compact(messages)

      summaries = Enum.filter(contents(result), &String.contains?(&1, "[Context Summary]"))
      assert length(summaries) == 1
    end

    test "compaction below the pipeline budget but above the real one still shrinks history" do
      # The DECISION uses the provider-reported token count (which includes the
      # system prompt and tool schemas); every per-step budget check used the
      # message-only estimate. So the pipeline could fire and then immediately
      # skip every step — "compacted" while changing nothing — and the next
      # request overflowed again on exactly the same history.
      #
      # Windows below ~66k use the ratio fallback: warn 60%, compact 75%,
      # block 90% (CompactionThresholds).
      messages = long_conversation(40)
      est = Compactor.estimate_tokens(messages)

      # Window where the MESSAGE-ONLY estimate (50% of window) sits under the
      # non-emergency target (warn_at = 60%)...
      cw = round(est / 0.5)
      assert cw < 66_000, "fixture must land in the ratio-fallback band"

      # ...but the REAL request (80% of window) is past compact_at (75%).
      real_tokens = round(cw * 0.80)

      Application.put_env(:optimal_system_agent, :max_context_tokens, cw)

      result = Compactor.maybe_compact(messages, real_tokens)

      assert Compactor.estimate_tokens(result) < est,
             "the pipeline measured message-only tokens against a budget derived " <>
               "from the real request, so it fired and then skipped every step"
    end

    test "emergency truncate alone still drops ordinary messages" do
      # The pin must be narrow: it protects the summary, not everything. With no
      # summary in play, emergency_truncate must still shed history.
      messages = long_conversation(120)
      force_emergency(messages)

      result = Compactor.maybe_compact(messages)

      ordinary =
        Enum.count(contents(result), fn c ->
          String.contains?(c, "User turn ") or String.contains?(c, "Assistant turn ")
        end)

      assert ordinary < 240, "emergency truncate must still drop ordinary history"
    end
  end
end
