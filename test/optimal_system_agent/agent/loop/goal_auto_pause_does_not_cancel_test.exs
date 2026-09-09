defmodule OptimalSystemAgent.Agent.Loop.GoalAutoPauseDoesNotCancelTest do
  @moduledoc """
  A goal auto-pause (stall, run-cap, usage-limits) or a manual `/goal pause`
  stops the PARENT turn from recursing further — it must never reach
  `Loop.cancel/1`, set a descendant's cooperative cancel flag, or cascade
  through `Fleet.stop_children/1`. Pausing the goal loop leaves all in-flight
  work — including a detached background/delegated subagent — running.

  This is the counterpart to the interrupt-cascade fix in `Loop.cancel/1`:
  that fix scopes what an EXPLICIT cancel/interrupt reaches; this test locks
  in that an auto-pause is not, and must never become, a second path into the
  same cascade.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Cancellation
  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Runtime.SessionManager

  setup do
    sid = "goal-pause-nocancel-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      GoalTracker.reset(sid)
      File.rm(ProgressLedger.path(sid))
    end)

    {:ok, session_id: sid}
  end

  defp incomplete(gaps) do
    %GoalVerifier.Result{verdict: :incomplete, reason: "still going", gaps: gaps}
  end

  # Start a real Loop and register it as a background child of `parent` —
  # exactly what a `delegate(background: true)` dispatch leaves behind.
  defp spawn_background_child(parent) do
    id = "agent:#{parent}:bg-#{System.unique_integer([:positive])}"

    RunStore.start_run(%{
      agent_id: id,
      parent_session_id: parent,
      role: "background",
      task: "long-running background work"
    })

    :ok = SessionManager.ensure_loop(id, user_id: "goal-pause-test", working_dir: File.cwd!())

    # Every test here asserts this Loop is STILL alive at the end (that is the
    # whole point) — clean it up regardless, or it leaks a live GenServer plus
    # a `:running` RunStore row into every other test sharing this VM.
    on_exit(fn -> Fleet.stop_node(id) end)

    id
  end

  defp alive?(session_id) do
    case SessionManager.lookup_loop(session_id) do
      {:ok, pid, _owner} -> Process.alive?(pid)
      _ -> false
    end
  end

  defp assert_untouched(bg) do
    assert alive?(bg), "a goal pause must not stop a running background child's Loop"

    refute Cancellation.cancelled?(bg),
           "a goal pause must not set the cooperative cancel flag on a background child"

    assert %{status: :running} = RunStore.get(bg),
           "a goal pause must not touch a background child's RunStore status"
  end

  describe "auto-pause via cross-turn stall detection" do
    test "leaves a running background child untouched", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      bg = spawn_background_child(sid)

      gaps = ["same blocker every round"]
      for _ <- 1..8, do: GoalTracker.advance(sid, incomplete(gaps), 1)

      assert GoalTracker.paused?(sid),
             "the stall must actually trip for this test to mean anything"

      assert GoalTracker.snapshot(sid).pause_reason == :no_progress

      assert_untouched(bg)
      Loop.clear_cancel(sid)
    end
  end

  describe "auto-pause via lifetime run cap" do
    test "leaves a running background child untouched", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 2)

      on_exit(fn -> Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs) end)

      GoalTracker.start(sid, "goal")
      bg = spawn_background_child(sid)

      GoalTracker.advance(sid, incomplete(["gap A"]), 1)
      GoalTracker.advance(sid, incomplete(["gap B"]), 2)

      assert GoalTracker.snapshot(sid).pause_reason == :run_cap
      assert GoalTracker.paused?(sid)

      assert_untouched(bg)
      Loop.clear_cancel(sid)
    end
  end

  describe "auto-pause via usage limits" do
    test "leaves a running background child untouched", %{session_id: sid} do
      GoalTracker.start(sid, "goal", token_budget: 100, tokens_used: 0)
      bg = spawn_background_child(sid)

      # `note_usage/2` tracks a DELTA from the baseline set on the first call
      # (or `tokens_used:` above) — seeded at 0, so this call's `used` is 200.
      GoalTracker.note_usage(sid, 200)

      assert GoalTracker.snapshot(sid).pause_reason == :usage_limits
      assert GoalTracker.paused?(sid)

      assert_untouched(bg)
      Loop.clear_cancel(sid)
    end
  end

  describe "manual /goal pause" do
    test "leaves a running background child untouched", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      bg = spawn_background_child(sid)

      GoalTracker.pause(sid, :user)

      assert GoalTracker.paused?(sid)
      assert GoalTracker.snapshot(sid).pause_reason == :user

      assert_untouched(bg)
      Loop.clear_cancel(sid)
    end
  end
end
