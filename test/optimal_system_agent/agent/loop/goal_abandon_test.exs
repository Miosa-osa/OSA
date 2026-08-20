defmodule OptimalSystemAgent.Agent.Loop.GoalAbandonTest do
  @moduledoc """
  The way out of a live goal that is no longer the work.

  `create_goal` refuses while a goal is unfinished — that freeze is what stops a
  hard objective being quietly swapped for an easy one, and it is load-bearing
  (see `goal_authoring_test.exs`, which pins the swapping direction and must
  stay green alongside this file).

  But the freeze was total. An agent whose work legitimately changed direction
  had no model-reachable exit at all:

    * `update_goal(complete)` is a claim, not a verdict — by design it cannot
      reach `:completed`;
    * `update_goal(blocked)` needs three CONSECUTIVE GOAL TURNS, and
      `turn_count` only advances at the start of a new top-level turn
      (`react_loop.ex` ticks it at `iteration == 0` only), so inside one
      unattended autonomous turn the streak can never leave 1/3;
    * pause / resume / clear are reserved to the user, reachable only through
      `/goal`.

  Under `overdrive` with nobody at the keyboard there is no user to type
  `/goal clear`, so the run ground on with its real work unanchorable.

  The exit added here is `update_goal(status: "abandoned")`: one call, terminal,
  permanently recorded against the objective it gave up on, and — the part that
  keeps it from being the easy-goal loophole — the successor goal INHERITS the
  turns and verification rounds already spent. Abandoning redirects a run; it
  does not refill its budget, which is the only thing swapping was ever worth.

  No provider is reachable in this environment. `advance/2` is driven with a
  synthetic `GoalVerifier.Result`, exactly as `goal_tracker_test.exs` does, so
  what is proven here is what the model's own tool calls can and cannot reach —
  not how a real skeptic panel votes.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Agent.TaskBrief
  alias OptimalSystemAgent.Tools.Builtins.Goal.Constants
  alias OptimalSystemAgent.Tools.Builtins.Goal.Handler

  # The lifetime verification-round cap is OFF by default: counting rounds
  # punished thoroughness, and Codex bounds a goal by token budget and elapsed
  # time instead. These cases exercise the cap itself, so they ask for one -
  # which is what "opt-in" means.
  setup do
    previous = Application.fetch_env(:optimal_system_agent, :goal_tracker_max_runs)
    Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, 12)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :goal_tracker_max_runs, v)
        :error -> Application.delete_env(:optimal_system_agent, :goal_tracker_max_runs)
      end
    end)

    :ok
  end

  setup do
    sid = "goal-abandon-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      GoalTracker.reset(sid)
      Steer.drain(sid)
      File.rm(ProgressLedger.path(sid))
      File.rm(TaskBrief.path(sid))
    end)

    {:ok, session_id: sid, ctx: %{session_id: sid}}
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

  defp create(ctx, objective), do: Handler.execute_create(%{"objective" => objective}, ctx)

  defp update(ctx, status) do
    with {:ok, input} <- Handler.validate_update(%{"status" => status}, ctx) do
      Handler.execute_update(input, ctx)
    end
  end

  # ── The deadlock this file exists to close ──────────────────────────────

  describe "an agent whose work changed direction" do
    test "cannot anchor the new work, and every other model-reachable move fails too", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Stop the mid-turn compact thrash in the context folder")

      # The new work is unrelated to the anchored objective.
      assert {:error, refusal} = create(ctx, "Fix the resize defect in the Rust TUI")
      assert refusal =~ "unfinished goal"

      # Completion is a claim, not a verdict — it cannot clear the goal.
      assert {:ok, _} = update(ctx, "complete")
      assert GoalTracker.status(sid) == :active
      assert {:error, _} = create(ctx, "Fix the resize defect in the Rust TUI")

      # Blocked needs three consecutive goal TURNS. Inside one unattended
      # autonomous turn `turn_count` never advances, so the streak is pinned.
      for _ <- 1..5 do
        assert {:ok, msg} = update(ctx, "blocked")
        assert msg =~ "1/3", "without a new top-level turn the blocked streak cannot advance"
      end

      assert GoalTracker.status(sid) == :active
      assert {:error, _} = create(ctx, "Fix the resize defect in the Rust TUI")

      # The exit. One call, and it must be a status the tool actually accepts.
      assert "abandoned" in Constants.model_statuses()
      assert {:ok, msg} = update(ctx, "abandoned")
      assert msg =~ "abandoned"

      assert GoalTracker.status(sid) == :abandoned
      refute GoalTracker.continue?(sid), "an abandoned goal must not keep driving the loop"
      refute GoalTracker.goal_loop?(sid)

      # And the new work anchors.
      assert {:ok, _} = create(ctx, "Fix the resize defect in the Rust TUI")
      assert GoalTracker.snapshot(sid).goal == "Fix the resize defect in the Rust TUI"
      assert GoalTracker.status(sid) == :active
    end

    test "the refusal names the way out instead of only naming the wall", %{ctx: ctx} do
      assert {:ok, _} = create(ctx, "The live objective")
      assert {:error, refusal} = create(ctx, "Unrelated work")

      # Every exit the model may reach is named, with its cost.
      assert refusal =~ "complete"
      assert refusal =~ "blocked"
      assert refusal =~ "abandoned"
      assert refusal =~ Constants.update_tool_name()

      # `/ask-user` is off by default, so "ask the user" must not be offered as
      # if it were available.
      refute refusal =~ "ask the user"
      refute refusal =~ "ask_user"
    end
  end

  # ── Abandonment is recorded, never erased ───────────────────────────────

  describe "what abandonment records" do
    test "the objective it gave up on survives in the ledger and the history", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "An objective that was given up on")
      goal_id = GoalTracker.goal_id(sid)

      assert {:ok, _} = update(ctx, "abandoned")

      snap = GoalTracker.snapshot(sid)
      assert Enum.any?(snap.history, &(&1 =~ "ABANDONED"))
      assert Enum.any?(snap.history, &(&1 =~ "An objective that was given up on"))
      assert snap.abandoned_count == 1

      ledger = File.read!(ProgressLedger.path(sid))
      assert ledger =~ "ABANDONED"
      assert ledger =~ goal_id, "the abandonment must be attributable to the goal it ended"
    end

    test "it survives a BEAM boundary — the sidecar, not the ETS cache, is the store", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Objective")
      assert {:ok, _} = update(ctx, "abandoned")
      assert {:ok, _} = create(ctx, "Successor")

      # Drop the cache exactly as a fresh `osa` invocation would.
      :ets.delete(:osa_goal_tracker, sid)

      snap = GoalTracker.snapshot(sid)
      assert snap.goal == "Successor"

      assert snap.abandoned_count == 1,
             "the abandonment count must round-trip through the sidecar"
    end
  end

  # ── The loophole direction: abandoning must not refill the budget ───────

  describe "abandonment redirects the run, it does not refill it" do
    test "the successor inherits the turns and verification rounds already spent", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Hard objective")

      GoalTracker.tick_turn(sid)
      GoalTracker.tick_turn(sid)
      # Distinct gaps, so the stall detector does not auto-pause the goal out
      # from under the test before it gets to abandon it.
      GoalTracker.advance(sid, result(:incomplete, gaps: ["lens: missing export_a"]))
      GoalTracker.advance(sid, result(:incomplete, gaps: ["lens: missing export_b"]))

      before = GoalTracker.snapshot(sid)
      assert before.turn_count == 2
      assert before.verify_run_count == 2

      assert {:ok, _} = update(ctx, "abandoned")
      assert {:ok, _} = create(ctx, "Easier objective")

      after_ = GoalTracker.snapshot(sid)

      assert after_.turn_count == before.turn_count,
             "abandoning must not hand the run a fresh turn budget"

      assert after_.verify_run_count == before.verify_run_count,
             "abandoning must not refund the lifetime verification rounds"

      assert after_.abandoned_count == 1
      assert after_.goal_id != before.goal_id, "a new goal is still a new identity"
    end

    test "abandoning one round short of the run cap does not buy a fresh cap", %{
      session_id: sid,
      ctx: ctx
    } do
      cap = GoalTracker.max_runs()
      assert {:ok, _} = create(ctx, "Hard objective")

      # Burn the lifetime cap down to its last round. Distinct gaps each time,
      # so it is the run cap being tested and not the stall detector.
      for n <- 1..(cap - 1) do
        GoalTracker.advance(sid, result(:incomplete, gaps: ["gap_#{n}"]))
      end

      assert GoalTracker.status(sid) == :active
      assert GoalTracker.snapshot(sid).verify_run_count == cap - 1

      assert {:ok, _} = update(ctx, "abandoned")
      assert {:ok, _} = create(ctx, "Easier objective")

      assert GoalTracker.snapshot(sid).verify_run_count == cap - 1,
             "the successor must start with the cap already almost spent"

      # And the very next round trips the cap, exactly as it would have on the
      # goal that was abandoned. Re-anchoring bought one round, not twelve.
      GoalTracker.advance(sid, result(:incomplete, gaps: ["gap_final"]))

      snap = GoalTracker.snapshot(sid)
      assert snap.status == :paused
      assert snap.pause_reason == :run_cap
      refute GoalTracker.continue?(sid)
    end

    test "abandoning cannot reach :completed", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")
      assert {:ok, _} = update(ctx, "abandoned")

      refute GoalTracker.completed?(sid)
      assert GoalTracker.status(sid) == :abandoned
    end

    test "the live objective still cannot be rewritten — only ended", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "The real objective")

      # No status the model may set edits the objective.
      for status <- Constants.model_statuses() -- ["abandoned"] do
        assert {:ok, _} = update(ctx, status)
        assert GoalTracker.snapshot(sid).goal == "The real objective"
      end

      # And the parameter surface still exposes nothing but `status`.
      params = OptimalSystemAgent.Tools.Builtins.Goal.UpdateTool.parameters()
      assert Map.keys(params["properties"]) == ["status"]

      # Abandoning ends the goal; it does not silently become the new one.
      assert {:ok, _} = update(ctx, "abandoned")
      assert GoalTracker.snapshot(sid).goal == "The real objective"
    end
  end

  # ── Edges ───────────────────────────────────────────────────────────────

  describe "edges" do
    test "there is nothing to abandon without a live goal", %{ctx: ctx} do
      assert {:error, msg} = update(ctx, "abandoned")
      assert msg =~ "no live goal"
    end

    test "an already-abandoned goal cannot be abandoned twice", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")
      assert {:ok, _} = update(ctx, "abandoned")

      assert {:error, msg} = update(ctx, "abandoned")
      assert msg =~ "no live goal"
      assert GoalTracker.snapshot(sid).abandoned_count == 1
    end

    test "an off-track goal may be abandoned", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")
      GoalTracker.advance(sid, result(:off_track))
      assert GoalTracker.status(sid) == :off_track

      assert {:ok, _} = update(ctx, "abandoned")
      assert GoalTracker.status(sid) == :abandoned
    end

    test "the user's /goal still re-anchors freely, with a clean budget", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Model objective")
      GoalTracker.tick_turn(sid)
      GoalTracker.advance(sid, result(:incomplete, gaps: ["g"]))

      # `start/3` is the USER's `/goal`. It is not the model's exit and keeps
      # its reset semantics — the operator is allowed a clean slate.
      snap = GoalTracker.start(sid, "User objective")
      assert snap.turn_count == 0
      assert snap.verify_run_count == 0
    end
  end
end
