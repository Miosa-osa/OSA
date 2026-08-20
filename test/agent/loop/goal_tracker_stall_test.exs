defmodule OptimalSystemAgent.Agent.Loop.GoalTrackerStallTest do
  @moduledoc """
  A goal spans MANY plans. One plan finishing is progress toward the goal, not
  the whole goal — so the goal's remaining gaps stay the same while real work
  lands, and that is the normal state of a large goal, not a stall.

  Reported: a run showed `Plan 6/6 ✔` next to "Goal auto-paused: no measurable
  progress across turns". Both were reported by the same session. The plan
  tracker saw the work; the goal tracker never looked at it, judging progress
  purely on whether the gap list changed.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier

  defp sid, do: "goal-stall-#{System.unique_integer([:positive])}"

  defp incomplete(gaps) do
    %GoalVerifier.Result{verdict: :incomplete, reason: "still going", gaps: gaps}
  end

  defp start(session_id) do
    GoalTracker.start(session_id, "organise the filesystem across every workspace")
  end

  describe "work landing is progress, whatever the gaps say" do
    test "identical gaps do NOT stall while tool calls keep landing" do
      # The reported failure: same gaps every round because the goal is big,
      # but the agent is working through it.
      s = sid()
      start(s)
      gaps = ["workspaces not all created", "signals unfiled"]

      for calls <- [10, 25, 60, 121, 200, 350] do
        GoalTracker.advance(s, incomplete(gaps), calls)
      end

      refute GoalTracker.paused?(s),
             "paused despite tool calls climbing every round: #{inspect(GoalTracker.snapshot(s))}"
    end

    test "it DOES stall when the gaps repeat and no work lands" do
      # The case the detector exists for: genuinely spinning.
      s = sid()
      start(s)
      gaps = ["same blocker"]

      for _ <- 1..8, do: GoalTracker.advance(s, incomplete(gaps), 42)

      assert GoalTracker.paused?(s), "a real stall was not caught"
      assert GoalTracker.snapshot(s).pause_reason == :no_progress
    end

    test "work landing resets a stall streak that had started" do
      s = sid()
      start(s)
      gaps = ["blocked on the same thing"]

      # Two rounds with nothing moving...
      GoalTracker.advance(s, incomplete(gaps), 5)
      GoalTracker.advance(s, incomplete(gaps), 5)
      refute GoalTracker.paused?(s)

      # ...then work lands. The streak must clear, not merely decay.
      GoalTracker.advance(s, incomplete(gaps), 6)
      assert GoalTracker.snapshot(s).stall_count == 0

      # And the goal survives another quiet round afterwards.
      GoalTracker.advance(s, incomplete(gaps), 6)
      refute GoalTracker.paused?(s)
    end
  end

  describe "changing gaps are still progress" do
    test "different gaps each round never stalls" do
      s = sid()
      start(s)

      for n <- 1..8, do: GoalTracker.advance(s, incomplete(["gap #{n}"]), 7)

      refute GoalTracker.paused?(s)
    end
  end

  describe "absence of evidence is not evidence of a stall" do
    test "a caller that passes no work marker cannot trigger a pause" do
      # `advance/2` has no marker. Treating "unknown" as "no work" would make
      # every legacy caller stall a healthy goal.
      s = sid()
      start(s)
      gaps = ["unchanged"]

      for _ <- 1..8, do: GoalTracker.advance(s, incomplete(gaps))

      refute GoalTracker.paused?(s),
             "advance/2 stalled a goal it has no progress information about"
    end
  end

  describe "the threshold" do
    test "tolerates more than two quiet rounds" do
      # Two was the old value and it false-paused constantly.
      s = sid()
      start(s)
      gaps = ["quiet"]

      GoalTracker.advance(s, incomplete(gaps), 3)
      GoalTracker.advance(s, incomplete(gaps), 3)

      refute GoalTracker.paused?(s), "paused after only two quiet rounds"
    end
  end

  describe "goals are not bounded by counting rounds" do
    setup do
      previous = Application.fetch_env(:optimal_system_agent, :goal_tracker_max_runs)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, v)
          :error -> Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs)
        end
      end)

      Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs)
      :ok
    end

    test "the verification round cap is off by default" do
      # Codex bounds a goal by token budget and elapsed time, with the budget
      # opt-in ("Omit unless explicitly requested") - never by a round count.
      # Counting rounds punished thoroughness: verifying more often made a goal
      # MORE likely to be killed.
      refute GoalTracker.run_cap_reached?(0)
      refute GoalTracker.run_cap_reached?(12)
      refute GoalTracker.run_cap_reached?(10_000)
    end

    test "it reads as unlimited rather than printing an atom" do
      assert GoalTracker.max_runs_label() == "unlimited"
    end

    test "many verification rounds alone never pause a goal" do
      s = sid()
      start(s)

      # 40 rounds, gaps changing so stall detection stays out of it. Under the
      # old cap of 12 this was paused with :run_cap less than a third of the way
      # through.
      for n <- 1..40, do: GoalTracker.advance(s, incomplete(["gap #{n}"]), n * 3)

      refute GoalTracker.paused?(s),
             "paused on round count: #{inspect(GoalTracker.snapshot(s))}"
    end

    test "an explicit cap is still honoured for a bounded run" do
      Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 3)

      assert GoalTracker.run_cap_reached?(3)
      refute GoalTracker.run_cap_reached?(2)
      assert GoalTracker.max_runs_label() == "3"
    end
  end

  describe "budgets bound a goal, not counters" do
    test "a goal with no budget is unbounded" do
      # Codex's token_budget is opt-in: "Omit unless explicitly requested".
      s = sid()
      start(s)

      GoalTracker.note_usage(s, 5_000_000)

      refute GoalTracker.paused?(s), "an unbudgeted goal was capped"
      assert GoalTracker.budget_remaining(GoalTracker.snapshot(s)) == :unlimited
    end

    test "a budgeted goal pauses when it spends the budget" do
      s = sid()
      GoalTracker.start(s, "big job", token_budget: 1_000, tokens_used: 500)

      GoalTracker.note_usage(s, 1_200)
      refute GoalTracker.paused?(s), "paused at 700 of 1000"

      GoalTracker.note_usage(s, 1_500)
      snap = GoalTracker.snapshot(s)

      assert snap.status == :paused
      assert snap.pause_reason == :usage_limits
      assert snap.tokens_used == 1_000
    end

    test "usage is measured from where the goal started, not session zero" do
      # Otherwise a goal anchored mid-session inherits every token spent before
      # it existed and dies immediately.
      s = sid()
      GoalTracker.start(s, "late goal", token_budget: 100, tokens_used: 900)

      GoalTracker.note_usage(s, 950)

      snap = GoalTracker.snapshot(s)
      assert snap.tokens_used == 50
      refute GoalTracker.paused?(s)
    end

    test "remaining budget is reported, not just enforced" do
      s = sid()
      GoalTracker.start(s, "job", token_budget: 500, tokens_used: 0)
      GoalTracker.note_usage(s, 200)

      assert GoalTracker.budget_remaining(GoalTracker.snapshot(s)) == 300
    end

    test "a nonsense budget is ignored rather than obeyed" do
      # Honouring 0 would end the goal before its first turn.
      for bad <- [0, -1, "lots", nil] do
        s = sid()
        GoalTracker.start(s, "job", token_budget: bad, tokens_used: 0)
        GoalTracker.note_usage(s, 10_000)

        refute GoalTracker.paused?(s), "budget #{inspect(bad)} was obeyed"
      end
    end

    test "elapsed time is tracked alongside tokens" do
      s = sid()
      start(s)

      assert is_integer(GoalTracker.elapsed_seconds(GoalTracker.snapshot(s)))
    end
  end
end
