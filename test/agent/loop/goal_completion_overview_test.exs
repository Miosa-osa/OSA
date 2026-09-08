defmodule OptimalSystemAgent.Agent.Loop.GoalCompletionOverviewTest do
  @moduledoc """
  "Walk away, come back to see GOAL COMPLETED plus a clean overview" — the
  payoff experience. `/goal` (and `/goal status`) now show a prominent banner
  plus a work overview (files touched) once a goal reaches a TERMINAL state
  (`:completed`, `:blocked`, `:abandoned`), reusing the SAME
  `VerificationEvidence` ledger the completion panel itself was judged
  against — not a second, possibly-disagreeing account of the work.

  Non-terminal states (`:active`, `:paused`, `:awaiting_user`) are unaffected:
  `/goal resume` still applies to them, so there is no "final" story to tell
  yet.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.{GoalTracker, GoalVerifier}
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger
  alias OptimalSystemAgent.Channels.CLI.Commands

  defp sid, do: "goal-overview-#{System.unique_integer([:positive])}"

  defp capture_cli(fun), do: ExUnit.CaptureIO.capture_io(fun)

  defp record_write(session_id, path) do
    Ledger.record(session_id, %{
      tool: "file_write",
      args: %{"path" => path},
      success: true
    })
  end

  setup do
    s = sid()

    on_exit(fn ->
      GoalTracker.reset(s)
      Ledger.reset(s)
    end)

    {:ok, session_id: s}
  end

  describe "a completed goal" do
    test "shows a GOAL COMPLETED banner and a work overview of what was touched", %{
      session_id: sid
    } do
      GoalTracker.start(sid, "ship the widget exporter")
      record_write(sid, "lib/widget/exporter.ex")
      record_write(sid, "lib/widget/router.ex")
      record_write(sid, "test/widget/exporter_test.exs")

      GoalTracker.advance(
        sid,
        %GoalVerifier.Result{verdict: :complete, reason: "all acceptance criteria met"}
      )

      output = capture_cli(fn -> Commands.dispatch("goal", sid) end)

      assert output =~ "GOAL COMPLETED"
      assert output =~ "ship the widget exporter"
      assert output =~ "Work overview"
      assert output =~ "3 file(s) touched"
      assert output =~ "lib/widget/exporter.ex"
      assert output =~ "lib/widget/router.ex"
      assert output =~ "test/widget/exporter_test.exs"
      assert output =~ "all acceptance criteria met"
    end

    test "acceptance criteria are shown alongside the completion banner", %{session_id: sid} do
      GoalTracker.start(sid, "ship the widget exporter",
        acceptance_criteria: "mix test passes and lib/exporter.ex exports dump/1"
      )

      GoalTracker.advance(sid, %GoalVerifier.Result{verdict: :complete, reason: "done"})

      output = capture_cli(fn -> Commands.dispatch("goal status", sid) end)

      assert output =~ "GOAL COMPLETED"
      assert output =~ "mix test passes and lib/exporter.ex exports dump/1"
    end

    test "no writes recorded says so instead of an empty section", %{session_id: sid} do
      GoalTracker.start(sid, "answer a question, no file changes needed")
      GoalTracker.advance(sid, %GoalVerifier.Result{verdict: :complete, reason: "answered"})

      output = capture_cli(fn -> Commands.dispatch("goal", sid) end)

      assert output =~ "GOAL COMPLETED"
      assert output =~ "No file writes recorded"
    end
  end

  describe "a blocked goal" do
    test "shows a GOAL BLOCKED banner, not a completion banner", %{session_id: sid} do
      GoalTracker.start(sid, "deploy to the locked-down environment")
      record_write(sid, "infra/deploy.yml")

      {:pending, 1, _} = GoalTracker.claim_blocked(sid)
      GoalTracker.tick_turn(sid)
      {:pending, 2, _} = GoalTracker.claim_blocked(sid)
      GoalTracker.tick_turn(sid)
      {:blocked, _} = GoalTracker.claim_blocked(sid)

      output = capture_cli(fn -> Commands.dispatch("goal", sid) end)

      assert output =~ "GOAL BLOCKED"
      refute output =~ "GOAL COMPLETED"
      assert output =~ "Work overview"
      assert output =~ "infra/deploy.yml"
    end
  end

  describe "non-terminal states get no banner or overview" do
    test "an active goal shows neither", %{session_id: sid} do
      GoalTracker.start(sid, "still working on it")
      record_write(sid, "lib/foo.ex")

      output = capture_cli(fn -> Commands.dispatch("goal", sid) end)

      refute output =~ "GOAL COMPLETED"
      refute output =~ "GOAL BLOCKED"
      refute output =~ "Work overview"
    end

    test "a merely paused goal shows neither — /goal resume still applies", %{session_id: sid} do
      GoalTracker.start(sid, "pause me")
      GoalTracker.pause(sid, :user)

      output = capture_cli(fn -> Commands.dispatch("goal", sid) end)

      refute output =~ "GOAL COMPLETED"
      refute output =~ "GOAL BLOCKED"
      refute output =~ "Work overview"
    end
  end
end
