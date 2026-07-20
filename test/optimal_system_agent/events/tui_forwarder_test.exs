defmodule OptimalSystemAgent.Events.TuiForwarderTest do
  @moduledoc """
  The TuiForwarder bridges Bus-only `:system_event` sub-events onto the
  per-session `osa:session:<id>` PubSub topic that the TUI streams, but ONLY for
  sub-events on its `@forward_events` allowlist. These tests pin that
  allowlist contract for `goal_verifier_round` (the goal-verification indicator)
  and confirm a non-allowlisted sub-event is NOT forwarded.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Events.Bus

  setup do
    sid = "tui-forwarder-test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
    {:ok, session_id: sid}
  end

  test "forwards goal_verifier_round (allowlisted) with its gaps intact", %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :goal_verifier_round,
      session_id: sid,
      round: 1,
      max_runs: 3,
      phase: :done,
      verdict: :incomplete,
      refuted_count: 2,
      total: 3,
      gaps: ["[completeness] error handling", "[verifiability] no test"]
    })

    assert_receive {:osa_event, event}, 2000
    assert event.type == :system_event
    assert event.event == :goal_verifier_round
    assert event.verdict == :incomplete
    assert event.gaps == ["[completeness] error handling", "[verifiability] no test"]
  end

  test "forwards the lightweight start-phase signal too", %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :goal_verifier_round,
      session_id: sid,
      round: 1,
      max_runs: 3,
      phase: :start
    })

    assert_receive {:osa_event, %{event: :goal_verifier_round, phase: :start}}, 2000
  end

  test "forwards scratchpad_activity (allowlisted) with a compact payload and NO contents",
       %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :scratchpad_activity,
      session_id: sid,
      agent: "agent:#{sid}:1",
      entry: "findings.md",
      action: :write,
      bytes: 2100
    })

    assert_receive {:osa_event, event}, 2000
    assert event.type == :system_event
    assert event.event == :scratchpad_activity
    assert event.agent == "agent:#{sid}:1"
    assert event.entry == "findings.md"
    assert event.action == :write
    assert event.bytes == 2100
    # The activity signal must NEVER carry file contents — only who/what/size.
    refute Map.has_key?(event, :content)
    refute Map.has_key?(event, "content")
  end

  test "does NOT forward a sub-event absent from the allowlist", %{session_id: sid} do
    Bus.emit(:system_event, %{
      event: :some_unlisted_internal_event,
      session_id: sid,
      detail: "should stay Bus-only"
    })

    refute_receive {:osa_event, %{event: :some_unlisted_internal_event}}, 500
  end
end
