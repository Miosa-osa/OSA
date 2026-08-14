defmodule OptimalSystemAgent.Agent.Loop.VerificationGatePerTurnResetTest do
  @moduledoc """
  The grounded-verification gate's re-prompt budget is documented — and only
  makes sense — as a **per-turn** cap: `@max_reprompts` exists so a stubborn
  model cannot trap the completion path *within one turn*.

  But the counter it reads, `state.verification_gate_prompts`, lives on the
  long-lived `Loop` state and nothing reset it. Two gate firings anywhere in a
  session therefore disabled the gate **permanently**, silently, and precisely
  on the long unattended sessions it exists to protect.

  `TurnPipeline.reset_per_turn_fields/1` is the one place the loop declares
  what "per turn" means, and its own docstring says a new per-turn counter must
  be added there. This asserts the gate's counter is.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger
  alias OptimalSystemAgent.Agent.Loop.VerificationGate

  setup do
    sid = "verif-reset-#{System.unique_integer([:positive])}"
    Ledger.reset(sid)
    on_exit(fn -> Ledger.reset(sid) end)
    {:ok, session_id: sid, path: Path.expand("/tmp/osa_verif_reset_#{sid}.ex")}
  end

  # The subset of loop state `reset_per_turn_fields/1` updates with the
  # struct-update syntax, which raises on a missing key.
  defp loop_state(sid) do
    %{
      session_id: sid,
      iteration: 3,
      overflow_retries: 1,
      auto_continues: 2,
      status: :thinking,
      exploration_done: true,
      recent_failure_signatures: ["x"],
      doom_recovery_count: 1,
      verification_gate_prompts: 0
    }
  end

  # A whole-file write, so this exercises the `:large` tier and its cap of 3.
  # (`:small` — a one-site edit — is capped at 2; see `VerificationAdequacyTest`.)
  defp unverified_write(sid, path) do
    Ledger.record(sid, %{
      tool: "file_write",
      args: %{"path" => path, "content" => String.duplicate("x\n", 60)},
      success: true
    })
  end

  test "the gate fires again on the NEXT turn after exhausting its budget",
       %{session_id: sid, path: path} do
    state = loop_state(sid)
    unverified_write(sid, path)

    # Turn 1: the model writes, the gate makes its case ONCE, and steps aside.
    # The cap was 3; the A/B measured the second and third pushbacks converting
    # nothing on the two tasks where they fired, at 37-41% of each task's tokens.
    state =
      Enum.reduce(1..1, state, fn _i, acc ->
        assert VerificationGate.needs_verification?(acc)
        {_d, acc} = VerificationGate.build_directive(acc)
        acc
      end)

    refute VerificationGate.needs_verification?(state),
           "the per-turn cap should have stepped the gate aside within this turn"

    assert state.verification_gate_prompts == 1

    # Turn 2 begins.
    state = TurnPipeline.reset_per_turn_fields(state)

    assert state.verification_gate_prompts == 0,
           "the per-turn re-prompt counter leaked into the next turn"

    # A fresh, unverified write in the new turn.
    unverified_write(sid, path)

    assert VerificationGate.needs_verification?(state),
           "the grounded-verification gate is permanently disabled after N firings in a session"
  end

  test "reset_per_turn_fields/1 sets the counter even when the key is absent",
       %{session_id: sid} do
    state = sid |> loop_state() |> Map.delete(:verification_gate_prompts)

    assert TurnPipeline.reset_per_turn_fields(state).verification_gate_prompts == 0
  end
end
