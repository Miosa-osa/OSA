defmodule OptimalSystemAgent.Agent.Loop.GoalIdentityTest do
  @moduledoc """
  A goal needs a stable identity, and the progress ledger's `## Log` has to be
  attributable to it.

  `ProgressLedger.set_goal/2` replaces the `## Goal` head IN PLACE while the
  previous goal's `## Log` lines stay exactly where they are. Without a
  boundary marker, `summarize/1` renders goal 2 above up to ten log lines that
  belong entirely to goal 1 — two durable records of intent silently
  disagreeing.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.ProgressLedger

  setup do
    sid = "goal-identity-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      GoalTracker.reset(sid)
      Steer.drain(sid)
      File.rm(ProgressLedger.path(sid))
    end)

    {:ok, session_id: sid}
  end

  describe "goal identity" do
    test "start/2 mints a goal_id and a re-issue mints a different one", %{session_id: sid} do
      first = GoalTracker.start(sid, "goal one")
      assert is_binary(first.goal_id) and first.goal_id != ""
      assert GoalTracker.goal_id(sid) == first.goal_id

      second = GoalTracker.start(sid, "goal two")
      assert is_binary(second.goal_id)

      refute second.goal_id == first.goal_id,
             "a re-issued goal reused the previous goal's identity"
    end

    test "the id is stable across pause -> resume -> complete", %{session_id: sid} do
      %{goal_id: id} = GoalTracker.start(sid, "long-lived goal")

      GoalTracker.pause(sid, :user)
      assert GoalTracker.goal_id(sid) == id

      GoalTracker.resume(sid)
      assert GoalTracker.goal_id(sid) == id

      GoalTracker.advance(sid, %OptimalSystemAgent.Agent.Loop.GoalVerifier.Result{
        verdict: :complete,
        reason: "done",
        refuted_count: 0,
        total: 3,
        gaps: []
      })

      assert GoalTracker.status(sid) == :completed
      assert GoalTracker.goal_id(sid) == id
    end
  end

  describe "the ledger log is attributable to the goal that produced it" do
    test "summarize/1 never shows the previous goal's entries under the new goal", %{
      session_id: sid
    } do
      GoalTracker.start(sid, "goal one: build the widget")

      for n <- 1..4 do
        ProgressLedger.append_entry(sid, "goal-one work item #{n}")
      end

      GoalTracker.start(sid, "goal two: delete the widget")
      ProgressLedger.append_entry(sid, "goal-two work item 1")

      {:ok, summary} = ProgressLedger.summarize(sid)

      assert summary =~ "goal two: delete the widget"
      assert summary =~ "goal-two work item 1"

      refute summary =~ "goal-one work item",
             "summarize/1 rendered the new goal over the OLD goal's log lines"
    end

    test "transitions logged under a goal carry that goal's id", %{session_id: sid} do
      %{goal_id: id} = GoalTracker.start(sid, "tagged goal")
      GoalTracker.pause(sid, :user)

      {:ok, contents} = ProgressLedger.read(sid)

      assert contents =~ "[goal-anchor:#{id}]"
      assert contents =~ "[goal:#{id}] [goal-tracker] goal PAUSED"
    end

    test "a ledger with no anchor keeps the old whole-log behaviour", %{session_id: sid} do
      # set_goal/2 without a :goal_id — the pre-existing callers (progress_note
      # tool, memory coordinator) must not change shape.
      ProgressLedger.set_goal(sid, "unanchored goal")
      ProgressLedger.append_entry(sid, "entry one")
      ProgressLedger.append_entry(sid, "entry two")

      {:ok, summary} = ProgressLedger.summarize(sid)
      assert summary =~ "entry one"
      assert summary =~ "entry two"
    end

    test "re-setting the SAME goal text does not emit a spurious boundary", %{session_id: sid} do
      ProgressLedger.set_goal(sid, "steady goal", goal_id: "id-a")
      ProgressLedger.append_entry(sid, "work happened")
      ProgressLedger.set_goal(sid, "steady goal", goal_id: "id-b")

      {:ok, summary} = ProgressLedger.summarize(sid)

      assert summary =~ "work happened",
             "an unchanged goal cut its own history off at a new boundary"
    end
  end
end
