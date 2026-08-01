defmodule OptimalSystemAgent.Agent.CompactorRealTokensTest do
  @moduledoc """
  Verifies that `Compactor.maybe_compact/4` feeds the REAL provider-reported
  input-token count (from the budget/accounting stage) into the compaction
  *decision* instead of the word-count heuristic (primitive #30).
  """
  # async: false — mutates the global :max_context_tokens operator override.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds

  setup do
    keys = [:max_context_tokens]

    prev = Enum.map(keys, &{&1, Application.get_env(:optimal_system_agent, &1)})

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

    # Pick a context window that puts the message-estimate comfortably BELOW
    # the shared reserve-based warn threshold, so a heuristic-only decision does
    # NOT compact — but close enough that a realistic provider-reported count
    # (which also counts the system prompt + tool schemas) does.
    max_context = round(est / 0.4)
    Application.put_env(:optimal_system_agent, :max_context_tokens, max_context)

    assert est < CompactionThresholds.warn_at(max_context),
           "fixture must sit below warn_at so the heuristic-only case is a true negative"

    {:ok, messages: messages, est: est, max_context: max_context}
  end

  test "heuristic-only decision leaves a sub-threshold history unchanged", %{messages: messages} do
    # ~60% utilization by estimate → below the 80% warn threshold.
    assert Compactor.maybe_compact(messages) == messages
  end

  test "nil / 0 known_tokens falls back to the heuristic estimate", %{messages: messages} do
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
