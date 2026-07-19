defmodule OptimalSystemAgent.Agent.Loop.TurnPipelineResetTest do
  @moduledoc """
  Regression test for the cross-turn state leak (finding #6): a fresh user
  turn must zero every per-turn counter, including the ones that were added
  to the loop after the original reset list was written
  (`reasoning_only_streak`, `goal_verifier_runs`, `goal_verifier_stall_count`,
  `target_continues`). Leaving any of these un-reset lets state bleed from
  one user turn into the next.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.TurnPipeline

  describe "reset_per_turn_fields/1" do
    test "zeroes all per-turn counters carried over from a dirty prior turn" do
      dirty_state = %{
        iteration: 7,
        overflow_retries: 2,
        auto_continues: 3,
        status: :done,
        exploration_done: true,
        recent_failure_signatures: [:sig1, :sig2],
        doom_recovery_count: 4,
        reasoning_only_streak: 2,
        goal_verifier_runs: 3,
        goal_verifier_stall_count: 5,
        target_continues: 5,
        # Fields NOT part of the reset contract — must survive untouched.
        session_id: "sess-1",
        messages: [%{role: "user", content: "hi"}]
      }

      reset = TurnPipeline.reset_per_turn_fields(dirty_state)

      assert reset.iteration == 0
      assert reset.overflow_retries == 0
      assert reset.auto_continues == 0
      assert reset.status == :thinking
      assert reset.exploration_done == false
      assert reset.recent_failure_signatures == []
      assert reset.doom_recovery_count == 0

      # The three fields that regressed (finding #6):
      assert reset.reasoning_only_streak == 0
      assert reset.goal_verifier_runs == 0
      assert reset.goal_verifier_stall_count == 0
      assert reset.target_continues == 0

      # Untouched fields survive.
      assert reset.session_id == "sess-1"
      assert reset.messages == [%{role: "user", content: "hi"}]
    end

    test "a session that exhausted goal_verifier_runs in turn 1 is verifiable again in turn 2" do
      exhausted = %{
        iteration: 0,
        overflow_retries: 0,
        auto_continues: 0,
        status: :thinking,
        exploration_done: false,
        recent_failure_signatures: [],
        doom_recovery_count: 0,
        reasoning_only_streak: 0,
        # Turn 1 hit the max_runs()=3 cap.
        goal_verifier_runs: 3,
        goal_verifier_stall_count: 0,
        target_continues: 0
      }

      reset = TurnPipeline.reset_per_turn_fields(exhausted)

      assert reset.goal_verifier_runs == 0
      assert reset.goal_verifier_runs < 3
    end
  end
end
