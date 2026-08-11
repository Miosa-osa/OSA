defmodule OptimalSystemAgent.Agent.Loop.GoalTrackerDurabilityTest do
  @moduledoc """
  The cross-turn goal state machine must survive the death of the BEAM that
  wrote it.

  Every `osa` invocation is its own BEAM (see `Agent.ProgressLedger`), so a
  state machine that lives only in the `:osa_goal_tracker` ETS table is
  re-created empty at every CLI invocation boundary. Both `paused?/1` and
  `continue?/1` then fall through their `nil ->` branch, and a goal that was
  auto-paused for `:no_progress` or `:run_cap` resumes autonomously with a
  fresh run budget — the circuit breaker resets exactly when it is needed.

  Dropping the ETS table is a faithful stand-in for that boundary: it is the
  same observable ("the in-memory cache no longer holds this session") without
  spawning a second OS process.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Agent.Loop.Steer

  @table :osa_goal_tracker

  setup do
    sid = "goal-durability-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      GoalTracker.reset(sid)
      Steer.drain(sid)
      File.rm(ProgressLedger.path(sid))
      Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs)
      Application.delete_env(:optimal_system_agent, :goal_tracker_stall_threshold)
    end)

    {:ok, session_id: sid}
  end

  defp result(verdict, opts \\ []) do
    %GoalVerifier.Result{
      verdict: verdict,
      reason: Keyword.get(opts, :reason, "reason"),
      refuted_count: 0,
      total: 3,
      gaps: Keyword.get(opts, :gaps, [])
    }
  end

  # Simulate the invocation boundary: the process-local cache goes away, the
  # durable store (if any) does not.
  defp drop_cache do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table)
    end

    :ok
  end

  describe "an auto-paused goal stays paused across an invocation boundary" do
    test "a :no_progress pause survives the cache dying", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_stall_threshold, 2)

      GoalTracker.start(sid, "ship the durable scheduler")

      gaps = ["lib/optimal_system_agent/agent/scheduler.ex still drops ticks"]
      GoalTracker.advance(sid, result(:incomplete, gaps: gaps))
      snap = GoalTracker.advance(sid, result(:incomplete, gaps: gaps))

      assert snap.status == :paused
      assert snap.pause_reason == :no_progress
      assert GoalTracker.paused?(sid)
      refute GoalTracker.continue?(sid)

      drop_cache()

      assert GoalTracker.paused?(sid),
             "an auto-paused goal resumed itself after the cache died — the breaker reset"

      refute GoalTracker.continue?(sid),
             "continue?/1 fell through its nil branch and handed the goal a fresh budget"

      assert GoalTracker.snapshot(sid).pause_reason == :no_progress
    end

    test "a :run_cap pause survives, and its run budget is NOT refilled", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 2)
      Application.put_env(:optimal_system_agent, :goal_tracker_stall_threshold, 99)

      GoalTracker.start(sid, "exhaust the lifetime run cap")

      GoalTracker.advance(sid, result(:incomplete, gaps: ["gap alpha"]))
      snap = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap beta"]))

      assert snap.status == :paused
      assert snap.pause_reason == :run_cap
      assert snap.verify_run_count == 2

      drop_cache()

      restored = GoalTracker.snapshot(sid)
      assert restored, "the paused goal vanished entirely with the cache"
      assert restored.status == :paused
      assert restored.pause_reason == :run_cap

      assert restored.verify_run_count == 2,
             "the lifetime verification budget was refilled to zero across the boundary"

      refute GoalTracker.reverify_due?(sid)
    end
  end

  describe "everything that gates continuation round-trips" do
    test "goal text, stall streak, fingerprint and history all survive", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_stall_threshold, 99)

      GoalTracker.start(sid, "a goal with a long tail")
      GoalTracker.tick_turn(sid)
      GoalTracker.tick_turn(sid)
      before = GoalTracker.advance(sid, result(:incomplete, gaps: ["lib/foo/bar.ex is missing"]))

      drop_cache()
      after_boundary = GoalTracker.snapshot(sid)

      assert after_boundary.goal == "a goal with a long tail"
      assert after_boundary.goal_id == before.goal_id
      assert after_boundary.turn_count == before.turn_count
      assert after_boundary.verify_run_count == before.verify_run_count
      assert after_boundary.stall_count == before.stall_count
      assert after_boundary.last_gap_fingerprint == before.last_gap_fingerprint
      assert after_boundary.history == before.history
      assert after_boundary.status == before.status
      assert after_boundary.phase == before.phase
    end

    test "goal_loop?/1 still answers true after the cache dies", %{session_id: sid} do
      GoalTracker.start(sid, "still anchored")
      assert GoalTracker.goal_loop?(sid)

      drop_cache()

      assert GoalTracker.goal_loop?(sid),
             "the anchored goal silently stopped being a goal loop at the invocation boundary"
    end

    test "a manual resume also survives (it must not re-pause)", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_stall_threshold, 1)
      GoalTracker.start(sid, "resume me")
      GoalTracker.advance(sid, result(:incomplete, gaps: ["some/path.ex"]))
      assert GoalTracker.paused?(sid)

      GoalTracker.resume(sid)
      drop_cache()

      assert GoalTracker.status(sid) == :active
      assert GoalTracker.continue?(sid)
    end
  end

  describe "reset/1 clears the durable half too" do
    test "a reset goal does not resurrect from disk", %{session_id: sid} do
      GoalTracker.start(sid, "temporary")
      assert File.exists?(GoalTracker.store_path(sid))

      GoalTracker.reset(sid)
      drop_cache()

      refute File.exists?(GoalTracker.store_path(sid))
      assert GoalTracker.snapshot(sid) == nil
    end
  end

  describe "a corrupted store fails closed" do
    test "an unreadable status decodes to :paused, never to :active", %{session_id: sid} do
      GoalTracker.start(sid, "corrupt me")
      File.write!(GoalTracker.store_path(sid), ~s({"session_id":"#{sid}","status":"banana"}))
      drop_cache()

      assert GoalTracker.status(sid) == :paused
      refute GoalTracker.continue?(sid)
    end

    test "unparseable JSON is treated as absent, not as a live goal", %{session_id: sid} do
      GoalTracker.start(sid, "corrupt me harder")
      File.write!(GoalTracker.store_path(sid), "{not json at all")
      drop_cache()

      assert GoalTracker.snapshot(sid) == nil
    end
  end
end
