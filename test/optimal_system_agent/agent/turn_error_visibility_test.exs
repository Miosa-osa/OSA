defmodule OptimalSystemAgent.Agent.TurnErrorVisibilityTest do
  @moduledoc """
  A turn that ended because every provider call failed must not look like a
  turn that ended because the model answered.

  Measured during benchmarking: a turn with 11 retries, the fallback chain
  exhausted and ZERO tokens exchanged still reported `status: ok` with
  `saw_done: true` and a clean `done` frame. Nothing in OSA's own telemetry
  said the turn had failed.

  The consequence was not theoretical. Two benchmark harnesses independently
  scored these as the MODEL failing to produce output:

    * The SWE-bench Pro ablation logged five outage-killed instances as
      `empty_patch, 0B` → `model_no_patch`, fault=model. Four of the five were
      instances the baseline had resolved, so a completed run would have shown
      a large apparent context-ablation effect that was really an outage — and
      since we EXPECTED that effect, it would have read as confirmation.
    * The head-to-head runner's generic attribution would have charged one
      exhausted account to all six arms' harnesses.

  For a human reading the TUI, returning the error as text is correct — you
  want to see it. For anything programmatic it is not.
  """
  use ExUnit.Case, async: true

  @react_loop "lib/optimal_system_agent/agent/loop/react_loop.ex"
  @loop "lib/optimal_system_agent/agent/loop.ex"

  test "the provider-failure path records the failure on state" do
    src = File.read!(@react_loop)

    # Matched WITHOUT the leading `state =` and without the intervening
    # whitespace. The behaviour is unchanged; only the formatting moved. The
    # turn-error map gained an `owner: :osa | :provider` field (the
    # `ErrorCatalog.fault_owner/1` work), which pushed the call past the line
    # limit, so `mix format` broke `state = Map.put(...)` across two lines and a
    # single-line source match stopped seeing it. Pinning the punctuation of a
    # formatter-owned line is not what this test is for.
    assert src =~ ~r/Map\.put\(state, :turn_error, %\{/,
           "react_loop no longer marks state when a turn ends on provider failure"

    # The fault attribution rides on the same map — a turn error whose owner is
    # OSA must not be reported to a harness as a provider outage.
    assert src =~ "owner: owner",
           "the turn error no longer carries fault attribution"
  end

  test "agent_response carries the marker on the wire" do
    src = File.read!(@loop)

    assert src =~ "turn_error: Map.get(state, :turn_error)",
           "agent_response no longer surfaces turn_error — an outage is invisible again"
  end

  test "the field is additive, so a normal turn carries nil" do
    # `Map.get/2` on a state that never failed returns nil rather than raising,
    # which is what keeps this backward compatible: existing consumers see a
    # field they do not read, and nothing changes shape.
    assert Map.get(%{session_id: "s"}, :turn_error) == nil
  end

  @tag :documented_gap
  test "the reply TUPLE is still indistinguishable — deliberately, for now" do
    # `run_and_reply` returns `{:reply, {:ok, response}, state}` even when the
    # turn died on a provider failure, so `process_message` gives `{:ok, msg}`
    # and `mix osa.run --format json` emits `type: "result"`.
    #
    # Not changed here because it IS a breaking contract change — every caller
    # expecting `{:ok, _}` would have to handle a new shape, including the TUI,
    # which correctly wants to render the error as text. The event-level marker
    # above closes the gap for the consumers that actually need it.
    #
    # This test exists so the remaining gap is recorded rather than forgotten.
    src = File.read!(@loop)

    assert src =~ "{:reply, {:ok, response}, state}",
           "the reply tuple changed — if that was deliberate, update this test " <>
             "and bench/FINDINGS.md entry 2, which documents the gap"
  end
end
