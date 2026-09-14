defmodule OptimalSystemAgent.Agent.Loop.GoalClearGhostTest do
  @moduledoc """
  `/goal clear` must leave the session with NO active goal, not a linger.

  Before this fix, `clear/1` only flipped the snapshot's `status` to
  `:cleared` and left `goal`/`history` populated. `Channels.CLI.Commands`'
  status display treated ANY snapshot carrying non-blank goal text as a live
  goal regardless of status, so `/goal` after `/goal clear` re-printed the
  full objective, acceptance criteria, and a stale "latest: ... INCOMPLETE
  round N" verdict from before the clear — a cleared goal was still fully
  queryable. Repeated `/goal clear` also always claimed "Goal cleared, not
  completed", never telling the user there was nothing left to clear.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Channels.CLI.Commands

  defp sid, do: "goal-clear-ghost-#{System.unique_integer([:positive])}"

  defp capture_cli(fun), do: ExUnit.CaptureIO.capture_io(fun)

  setup do
    s = sid()
    on_exit(fn -> GoalTracker.reset(s) end)
    {:ok, session_id: s}
  end

  describe "/goal after /goal clear" do
    test "reports no active goal instead of the stale objective/criteria/verdict", %{
      session_id: s
    } do
      GoalTracker.start(s, "ship the widget exporter", acceptance_criteria: "mix test passes")

      result = %GoalVerifier.Result{
        verdict: :incomplete,
        reason: "3/3 skeptics refuted goal completion",
        refuted_count: 3,
        total: 3,
        gaps: []
      }

      GoalTracker.advance(s, result)

      capture_cli(fn -> Commands.dispatch("goal clear", s) end)

      status_out = capture_cli(fn -> Commands.dispatch("goal", s) end)

      refute status_out =~ "ship the widget exporter"
      refute status_out =~ "mix test passes"
      refute status_out =~ "INCOMPLETE"
      refute status_out =~ "status:"
      assert status_out =~ "No active goal"
    end

    test "is idempotent: clearing an already-cleared goal says so cleanly", %{session_id: s} do
      GoalTracker.start(s, "ship the widget exporter")
      capture_cli(fn -> Commands.dispatch("goal clear", s) end)

      second_clear_out = capture_cli(fn -> Commands.dispatch("goal clear", s) end)

      assert second_clear_out =~ "No active goal to clear"
      refute second_clear_out =~ "Goal cleared"
    end

    test "clearing a session that never anchored a goal says so cleanly", %{session_id: s} do
      clear_out = capture_cli(fn -> Commands.dispatch("goal clear", s) end)

      assert clear_out =~ "No active goal to clear"
      refute clear_out =~ "Goal cleared"
    end

    test "a cleared goal does not drive auto-continue or count as a live goal loop", %{
      session_id: s
    } do
      GoalTracker.start(s, "ship the widget exporter")
      capture_cli(fn -> Commands.dispatch("goal clear", s) end)

      refute GoalTracker.continue?(s)
      refute GoalTracker.goal_loop?(s)
      # Plain interactive posture (no overdrive, no long turn): the only thing
      # that could make `enabled?/1` true here is a live goal loop, and the
      # goal was just cleared.
      refute GoalTracker.enabled?(%{session_id: s})
    end
  end
end
