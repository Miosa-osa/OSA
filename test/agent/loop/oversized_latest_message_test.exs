defmodule OptimalSystemAgent.Agent.Loop.OversizedLatestMessageTest do
  @moduledoc """
  Reproduces the audit-item-3 defect end to end through the REAL `ReactLoop`:
  a latest user message that is, on its own, bigger than the context window
  survives `ContextCollapse.collapse/2` (tool-results only) and the
  compactor's hot-zone selection (which deliberately preserves the single
  most-recent turn verbatim) unchanged, so the turn used to fail as a context
  overflow after exactly 3 recovery attempts, forever, on every retry of the
  same corrupted turn.

  Pins the fix's WIRING (not just the isolated function — see
  `context_collapse_test.exs` for that): `ReactLoop` now tries
  `ContextCollapse.trim_oversized_latest_message/3` exactly once before
  giving up, and never twice.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Test.MockProvider

  # Comfortably over half of the 200k-token fallback window `mock-model-1.0`
  # resolves to (the registry has no real entry for it, so `ContextWindow`
  # is genuinely `:unknown` here and `ContextCollapse` falls back to
  # `CompactionThresholds.fallback_window/0`) — ~195k estimated tokens.
  @huge_text String.duplicate("word ", 150_000)
  @overflow_reason "Anthropic returned 400: prompt exceeds the maximum context length for this model"

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_max_iter = Application.get_env(:optimal_system_agent, :max_iterations)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 20)
    Application.put_env(:optimal_system_agent, :mock_provider_error, @overflow_reason)
    MockProvider.reset()
    MockProvider.reset_round_trips()

    on_exit(fn ->
      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_max_iter,
        do: Application.put_env(:optimal_system_agent, :max_iterations, prev_max_iter),
        else: Application.delete_env(:optimal_system_agent, :max_iterations)

      Application.delete_env(:optimal_system_agent, :mock_provider_error)
    end)

    :ok
  end

  defp sid, do: "oversized-msg-#{System.unique_integer([:positive])}"

  # Real conversational history BEFORE the oversized turn, so the compactor
  # has genuine older content to fold — matching the audit scenario, and
  # exercising its documented invariant that the single most-recent turn is
  # always preserved VERBATIM no matter how large (as opposed to a
  # single-message history, where an emergency pipeline has nothing else to
  # work with and may treat the lone message differently).
  defp older_turns do
    for i <- 1..6 do
      [
        %{role: "user", content: "turn #{i}: what's the status of task #{i}?"},
        %{role: "assistant", content: "Task #{i} is on track, nothing blocking."}
      ]
    end
    |> List.flatten()
  end

  defp base_state do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: sid(),
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      overflow_retries: 0,
      messages: older_turns() ++ [%{role: "user", content: @huge_text}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  test "the turn attempts the last-resort trim exactly once, then halts cleanly (never loops forever)" do
    {response, new_state} = ReactLoop.run(base_state())

    # A provider that keeps rejecting the request as too large — even the
    # TRIMMED version, in this deliberately worst-case test — still has to
    # reach a TERMINAL answer, not hang or spin.
    assert is_binary(response)
    assert response =~ "exceeded the context window"

    # The one-shot guard fired exactly once — not skipped, not repeated.
    assert new_state.latest_message_trimmed == true

    # The trim actually happened: the real message content in history was
    # rewritten to the head+tail excerpt before the turn gave up, not just a
    # silent internal flag with no observable effect.
    assert Enum.any?(new_state.messages, fn msg ->
             content = Map.get(msg, :content) || Map.get(msg, "content")
             is_binary(content) and content =~ "larger than half the model's context window"
           end)

    # Bounded round-trips: 3 collapse/compaction retries + at most a small,
    # fixed number of compaction-internal summarizer attempts + one more after
    # the trim. A regression that re-triggers the trim (or the overflow retry
    # loop) on every subsequent iteration would blow this budget.
    assert MockProvider.round_trips() < 30,
           "the turn made #{MockProvider.round_trips()} provider round-trips — the one-shot " <>
             "trim guard (or the 3-attempt overflow retry budget) is not bounding this turn"
  end

  test "a SECOND overflowing turn in the same session gets its own fresh one-shot trim" do
    # `latest_message_trimmed` lives on the per-run state map, so a later,
    # unrelated turn (its own `ReactLoop.run/1` call with a fresh
    # `overflow_retries`/`latest_message_trimmed`) is never permanently
    # locked out of the recovery by an earlier turn's guard.
    {_response1, state1} = ReactLoop.run(base_state())
    assert state1.latest_message_trimmed == true

    {response2, state2_after} = ReactLoop.run(base_state())

    assert response2 =~ "exceeded the context window"
    assert state2_after.latest_message_trimmed == true
  end
end
