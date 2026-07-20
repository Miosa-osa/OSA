defmodule OptimalSystemAgent.Agent.Loop.GoalTrackerTest do
  @moduledoc """
  P1 gap #4: persistent CROSS-TURN goal orchestration — status/phase state
  machine, cross-turn stall auto-pause, run cap, and reverify cadence.

  These are pure unit tests against the ETS-backed store; no LLM/loop is
  spawned. `Steer` and `ProgressLedger` are the real modules (both are
  side-effecting but self-contained / best-effort), so we assert on their
  observable state (`Steer.drain/1`, `ProgressLedger.read/1`) rather than
  stubbing them.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.ProgressLedger

  setup do
    sid = "goal-tracker-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      GoalTracker.reset(sid)
      Steer.drain(sid)
      File.rm(ProgressLedger.path(sid))
      Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs)
      Application.delete_env(:optimal_system_agent, :goal_tracker_reverify_after)
      Application.delete_env(:optimal_system_agent, :goal_tracker_stall_threshold)
      Application.delete_env(:optimal_system_agent, :goal_tracker_enabled)
    end)

    {:ok, session_id: sid}
  end

  defp result(verdict, opts \\ []) do
    %GoalVerifier.Result{
      verdict: verdict,
      reason: Keyword.get(opts, :reason, "reason"),
      refuted_count: Keyword.get(opts, :refuted_count, 0),
      total: Keyword.get(opts, :total, 3),
      gaps: Keyword.get(opts, :gaps, [])
    }
  end

  # ── Lifecycle / status machine ──────────────────────────────────────────

  describe "start/2 and ensure/1" do
    test "start/2 seeds an active/executing snapshot and writes the ledger goal", %{
      session_id: sid
    } do
      snap = GoalTracker.start(sid, "ship the widget exporter")

      assert snap.status == :active
      assert snap.phase == :executing
      assert snap.goal == "ship the widget exporter"
      assert GoalTracker.status(sid) == :active

      {:ok, ledger} = ProgressLedger.read(sid)
      assert ledger =~ "ship the widget exporter"
    end

    test "ensure/1 lazily creates an active entry without a goal", %{session_id: sid} do
      refute GoalTracker.snapshot(sid)
      snap = GoalTracker.ensure(sid)
      assert snap.status == :active
      assert GoalTracker.snapshot(sid) != nil
    end

    test "continue?/1 defaults to true for an untracked session", %{session_id: sid} do
      assert GoalTracker.continue?(sid)
    end
  end

  describe "tick_turn/1" do
    test "increments turn_count and rounds_since_verify while active", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      GoalTracker.tick_turn(sid)
      snap = GoalTracker.tick_turn(sid)

      assert snap.turn_count == 2
      assert snap.rounds_since_verify == 2
    end

    test "does not advance counters once paused", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      GoalTracker.pause(sid, :user)
      snap = GoalTracker.tick_turn(sid)

      assert snap.turn_count == 0
      assert snap.status == :paused
    end
  end

  # ── Transitions ──────────────────────────────────────────────────────────

  describe "advance/2 — :complete" do
    test "transitions active -> completed", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      snap = GoalTracker.advance(sid, result(:complete, reason: "all skeptics agree"))

      assert snap.status == :completed
      assert snap.phase == :idle
      assert GoalTracker.completed?(sid)
      refute GoalTracker.continue?(sid)

      {:ok, ledger} = ProgressLedger.read(sid)
      assert ledger =~ "COMPLETED"
    end
  end

  describe "advance/2 — :off_track" do
    test "transitions active -> off_track and queues a re-plan Steer nudge", %{session_id: sid} do
      GoalTracker.start(sid, "goal")

      snap =
        GoalTracker.advance(
          sid,
          result(:off_track, reason: "contradiction", gaps: ["goal requires a deleted API"])
        )

      assert snap.status == :off_track
      assert snap.phase == :planning
      assert GoalTracker.off_track?(sid)
      # off_track is a redirect, not a hard stop — the loop may keep going.
      assert GoalTracker.continue?(sid)

      [nudge] = Steer.drain(sid)
      assert nudge =~ "OFF-TRACK"
      assert nudge =~ "deleted API"
    end
  end

  describe "advance/2 — :incomplete (no stall, keeps going)" do
    test "stays active and queues no nudge before reverify_after elapses", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      snap = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))

      assert snap.status == :active
      assert snap.verify_run_count == 1
      assert Steer.drain(sid) == []
    end
  end

  # ── Cross-turn stall auto-pause ─────────────────────────────────────────

  describe "cross-turn stall auto-pause" do
    test "two identical gap fingerprints ACROSS TURNS auto-pause with :no_progress", %{
      session_id: sid
    } do
      GoalTracker.start(sid, "goal")

      # Round 1 (turn N): incomplete, cites gap A — first occurrence, no stall yet.
      snap1 = GoalTracker.advance(sid, result(:incomplete, gaps: ["still missing the CSV export"]))
      assert snap1.status == :active
      assert snap1.stall_count == 1

      # A turn boundary elapses in between (proves this is CROSS-turn, not
      # within a single ReactLoop.run/1 recursion).
      GoalTracker.tick_turn(sid)

      # Round 2 (turn N+1): identical gap fingerprint -> stall trips.
      snap2 = GoalTracker.advance(sid, result(:incomplete, gaps: ["still missing the CSV export"]))

      assert snap2.status == :paused
      assert snap2.pause_reason == :no_progress
      assert GoalTracker.paused?(sid)
      refute GoalTracker.continue?(sid)

      {:ok, ledger} = ProgressLedger.read(sid)
      assert ledger =~ "PAUSED (no_progress)"
    end

    test "a different gap fingerprint resets the stall streak", %{session_id: sid} do
      GoalTracker.start(sid, "goal")

      snap1 = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert snap1.stall_count == 1

      snap2 = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap B"]))
      assert snap2.status == :active
      assert snap2.stall_count == 1
    end

    test "gap_fingerprint/1 is order-independent (normalized + sorted)", %{session_id: _sid} do
      fp1 = GoalTracker.gap_fingerprint(["Gap A", "gap b"])
      fp2 = GoalTracker.gap_fingerprint(["gap b", "  gap a  "])
      assert fp1 == fp2
    end

    test "resume/1 clears the stall streak so a repeat is a fresh first occurrence", %{
      session_id: sid
    } do
      GoalTracker.start(sid, "goal")
      GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      GoalTracker.tick_turn(sid)
      paused = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert paused.status == :paused

      resumed = GoalTracker.resume(sid)
      assert resumed.status == :active
      assert resumed.stall_count == 0
      assert resumed.last_gap_fingerprint == nil

      # Same fingerprint again must NOT immediately re-stall.
      snap = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert snap.status == :active
    end

    test "custom stall_threshold is honored", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_stall_threshold, 3)
      GoalTracker.start(sid, "goal")

      snap1 = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert snap1.status == :active

      snap2 = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert snap2.status == :active, "must not stall before the custom threshold (3)"

      snap3 = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert snap3.status == :paused
    end
  end

  # ── Lifetime run cap ─────────────────────────────────────────────────────

  describe "lifetime run cap" do
    test "auto-pauses with :run_cap once the cap is exhausted (distinct gaps, no stall)", %{
      session_id: sid
    } do
      Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 2)
      GoalTracker.start(sid, "goal")

      snap1 = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert snap1.status == :active

      snap2 = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap B"]))
      assert snap2.status == :paused
      assert snap2.pause_reason == :run_cap
      refute GoalTracker.continue?(sid)
    end
  end

  # ── Reverify cadence ─────────────────────────────────────────────────────

  describe "reverify_due?/1" do
    test "true for an untracked session (defers to GoalVerifier's own gating)", %{
      session_id: sid
    } do
      assert GoalTracker.reverify_due?(sid)
    end

    test "true on the very first round even with rounds_since_verify at 0", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      assert GoalTracker.reverify_due?(sid)
    end

    test "false immediately after a round, true again once reverify_after turns elapse", %{
      session_id: sid
    } do
      Application.put_env(:optimal_system_agent, :goal_tracker_reverify_after, 3)
      GoalTracker.start(sid, "goal")

      GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      refute GoalTracker.reverify_due?(sid), "must not re-verify immediately after a round"

      GoalTracker.tick_turn(sid)
      refute GoalTracker.reverify_due?(sid)

      GoalTracker.tick_turn(sid)
      refute GoalTracker.reverify_due?(sid)

      snap = GoalTracker.tick_turn(sid)
      assert snap.rounds_since_verify == 3
      assert GoalTracker.reverify_due?(sid), "due again once reverify_after turns have elapsed"
    end

    test "false once the goal is paused or completed", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      GoalTracker.pause(sid, :user)
      refute GoalTracker.reverify_due?(sid)

      GoalTracker.resume(sid)
      GoalTracker.advance(sid, result(:complete))
      refute GoalTracker.reverify_due?(sid)
    end

    test "false once the lifetime run cap is exhausted, even if reverify_after elapsed", %{
      session_id: sid
    } do
      Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 1)
      Application.put_env(:optimal_system_agent, :goal_tracker_reverify_after, 1)
      GoalTracker.start(sid, "goal")

      GoalTracker.advance(sid, result(:off_track, reason: "blocked"))
      GoalTracker.tick_turn(sid)

      refute GoalTracker.reverify_due?(sid)
    end
  end

  # ── Reverify nudge (mirrors grok's render_goal_reverify_block) ──────────

  describe "reverify nudge" do
    test "queues a Steer nudge once verify_run_count reaches reverify_after", %{
      session_id: sid
    } do
      Application.put_env(:optimal_system_agent, :goal_tracker_reverify_after, 2)
      GoalTracker.start(sid, "goal")

      GoalTracker.advance(sid, result(:incomplete, gaps: ["gap A"]))
      assert Steer.drain(sid) == [], "no nudge before verify_run_count reaches the threshold"

      GoalTracker.tick_turn(sid)
      snap = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap B"]))
      assert snap.status == :active
      [nudge] = Steer.drain(sid)
      assert nudge =~ "Re-verify before continuing."
    end

    test "escalates the lead line past 3x the threshold", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_reverify_after, 1)
      Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 10)
      GoalTracker.start(sid, "goal")

      for n <- 1..3 do
        GoalTracker.advance(sid, result(:incomplete, gaps: ["gap #{n}"]))
        Steer.drain(sid)
      end

      snap = GoalTracker.advance(sid, result(:incomplete, gaps: ["gap 4"]))
      assert snap.verify_run_count == 4
      [nudge] = Steer.drain(sid)
      assert nudge =~ "STOP DRIFTING"
    end
  end

  # ── Manual controls ──────────────────────────────────────────────────────

  describe "pause/2 and resume/1" do
    test "manual pause halts continue?/1", %{session_id: sid} do
      GoalTracker.start(sid, "goal")
      GoalTracker.pause(sid, :user)
      refute GoalTracker.continue?(sid)
      assert GoalTracker.snapshot(sid).pause_reason == :user
    end
  end

  # ── enabled?/1 config gate ───────────────────────────────────────────────

  describe "enabled?/1 smart activation" do
    test "OFF for a short interactive ask-mode turn under :auto", %{session_id: _sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_enabled, :auto)
      refute GoalTracker.enabled?(%{})
      refute GoalTracker.enabled?(%{iteration: 1, permission_mode: :ask})
    end

    test "true when explicitly configured on, even in ask mode", %{session_id: _sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_enabled, true)
      assert GoalTracker.enabled?(%{permission_mode: :ask})
    end

    test "explicit false forces OFF even under overdrive", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_enabled, false)
      OptimalSystemAgent.Agent.PermissionMode.put(sid, :overdrive)
      refute GoalTracker.enabled?(%{session_id: sid})
      OptimalSystemAgent.Agent.PermissionMode.clear(sid)
    end

    # Smart activation: overdrive/bypass is the operator's autonomous mode
    # where finishing-correctly matters, so under :auto the cross-turn tracker
    # turns ON (mirrors GoalVerifier.autonomous_posture?/1).
    test "ON under overdrive mode under :auto", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_enabled, :auto)
      OptimalSystemAgent.Agent.PermissionMode.put(sid, :overdrive)
      assert GoalTracker.enabled?(%{session_id: sid})
      OptimalSystemAgent.Agent.PermissionMode.clear(sid)
    end

    test "ON under bypass mode under :auto", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_enabled, :auto)
      OptimalSystemAgent.Agent.PermissionMode.put(sid, :bypass)
      assert GoalTracker.enabled?(%{session_id: sid})
      OptimalSystemAgent.Agent.PermissionMode.clear(sid)
    end

    test "ON when driving an anchored goal loop under :auto", %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_tracker_enabled, :auto)
      GoalTracker.start(sid, "ship the exporter")
      assert GoalTracker.enabled?(%{session_id: sid})
    end
  end

  describe "goal_loop?/1" do
    test "false for an untracked session", %{session_id: sid} do
      refute GoalTracker.goal_loop?(sid)
    end

    test "false for a bare ensure/1 entry with no goal text", %{session_id: sid} do
      GoalTracker.ensure(sid)
      refute GoalTracker.goal_loop?(sid)
    end

    test "true once a real goal is anchored via start/2", %{session_id: sid} do
      GoalTracker.start(sid, "ship the exporter")
      assert GoalTracker.goal_loop?(sid)
    end

    test "false once the anchored goal is completed", %{session_id: sid} do
      GoalTracker.start(sid, "ship the exporter")
      GoalTracker.advance(sid, result(:complete))
      refute GoalTracker.goal_loop?(sid)
    end
  end
end
