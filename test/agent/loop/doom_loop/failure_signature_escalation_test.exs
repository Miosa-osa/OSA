defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignatureEscalationTest do
  @moduledoc """
  A model that keeps making the same STRUCTURAL mistake (wrong/missing field)
  while jittering the payload used to slip past the strict threshold (3) - each
  jittered value minted a fresh args digest - and only tripped the broad
  backstop at 6. Validation-class failures are now keyed on argument SHAPE, so
  the repeat collapses onto one strict signature and escalates at 3.

  This complements `DoomLoopProgressTest`, which guards the opposite direction:
  genuinely different CONTENT-mismatch failures must stay distinct.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature

  defp state(overrides \\ []) do
    Enum.into(overrides, %{
      session_id: "doom-esc-#{System.unique_integer([:positive, :monotonic])}",
      messages: [],
      recent_failure_signatures: []
    })
  end

  defp call(name, args),
    do: %{id: "tc-#{System.unique_integer([:positive, :monotonic])}", name: name, arguments: args}

  test "a validation error repeated with jittered values escalates at 3, not 6" do
    # Same wrong SHAPE (keys find + new_string, missing the required `to`),
    # different VALUE each time. Under value-keyed signatures this would need six
    # tries; keyed on shape it collapses to one strict signature and recovers at 3.
    body = "Error: file_transform requires string `to`"

    s =
      Enum.reduce(1..3, state(), fn i, acc ->
        tc = call("file_transform", %{"find" => "x", "new_string" => "content #{i}"})
        results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]
        assert {:ok, next} = FailureSignature.check(results, [tc], acc)
        next
      end)

    assert s.doom_recovery_count == 1
    assert Enum.any?(s.messages, fn m -> m.content =~ "DOOM LOOP RECOVERY" end),
           "the strict threshold should fire a recovery directive by the third jittered repeat"
  end

  test "a content-mismatch error with jittered args stays value-keyed (no early escalation)" do
    # 'old_string not found' is a content mismatch, NOT a validation error:
    # different args are genuinely different edits and must remain distinct so
    # correct-but-different work never trips the detector.
    s =
      Enum.reduce(1..3, state(), fn i, acc ->
        tc = call("file_edit", %{"path" => "f.ex", "old_string" => "target #{i}"})
        body = "Error: old_string not found in f.ex"
        results = [{tc, {%{role: "tool", tool_call_id: tc.id, content: body}, body}}]
        assert {:ok, next} = FailureSignature.check(results, [tc], acc)
        next
      end)

    assert length(s.recent_failure_signatures) == 3
    assert s.messages == []
  end
end
