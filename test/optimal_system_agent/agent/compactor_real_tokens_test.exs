defmodule OptimalSystemAgent.Agent.CompactorRealTokensTest do
  @moduledoc """
  Verifies that `Compactor.maybe_compact/2` feeds the REAL provider-reported
  input-token count (from the budget/accounting stage) into the compaction
  *decision* instead of the word-count heuristic (primitive #30).
  """
  # async: false — mutates global compaction threshold / max-context config.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor

  setup do
    keys = [
      :max_context_tokens,
      :compaction_warn,
      :compaction_aggressive,
      :compaction_emergency
    ]

    prev = Enum.map(keys, &{&1, Application.get_env(:optimal_system_agent, &1)})

    # Deterministic thresholds regardless of env.
    Application.put_env(:optimal_system_agent, :compaction_warn, 0.80)
    Application.put_env(:optimal_system_agent, :compaction_aggressive, 0.85)
    Application.put_env(:optimal_system_agent, :compaction_emergency, 0.95)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:optimal_system_agent, k)
        {k, v} -> Application.put_env(:optimal_system_agent, k, v)
      end)
    end)

    # 60 alternating user/assistant messages with modest content.
    messages =
      Enum.flat_map(1..30, fn i ->
        [
          %{role: "user", content: "User turn #{i} with a little bit of content to score."},
          %{role: "assistant", content: "Assistant reply #{i} with some more words here too."}
        ]
      end)

    est = Compactor.estimate_tokens(messages)

    # Pick a context window so the message-estimate sits at ~60% utilization:
    # below the 80% warn threshold (so a heuristic-only decision does NOT
    # compact) but above the 50% emergency *target* (so once compaction is
    # triggered, the pipeline actually does work).
    max_context = round(est / 0.6)
    Application.put_env(:optimal_system_agent, :max_context_tokens, max_context)

    {:ok, messages: messages, est: est, max_context: max_context}
  end

  test "heuristic-only decision leaves a sub-threshold history unchanged", %{messages: messages} do
    # ~60% utilization by estimate → below the 80% warn threshold.
    assert Compactor.maybe_compact(messages) == messages
  end

  test "nil / 0 known_tokens preserves maybe_compact/1 behaviour", %{messages: messages} do
    assert Compactor.maybe_compact(messages, nil) == messages
    assert Compactor.maybe_compact(messages, 0) == messages
  end

  test "a large REAL token count triggers compaction the estimate would have missed",
       %{messages: messages, max_context: max_context} do
    # Provider reported near-full context (system prompt + tools push real usage
    # far past what the message-only heuristic sees) → emergency compaction.
    real_tokens = round(max_context * 0.99)

    result = Compactor.maybe_compact(messages, real_tokens)

    # The decision fired and the pipeline shrank the history.
    assert length(result) < length(messages)
  end
end
