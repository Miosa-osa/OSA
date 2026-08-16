defmodule OptimalSystemAgent.Agent.Loop.GoalAuthoringTest do
  @moduledoc """
  The self-authored goal: the agent writes its own objective and acceptance
  criteria, and cannot then write itself an easy finish line.

  Ported alongside Codex's `create_goal` / `update_goal` pair. The properties
  under test are the ones that make a self-authored goal safe to run
  autonomously:

    * the objective is frozen once anchored (Codex: `create_goal` fails while an
      unfinished goal exists, and `update_goal` hardcodes `objective: None`);
    * `update_goal(status: "complete")` is a CLAIM, never a verdict;
    * `update_goal(status: "blocked")` needs three consecutive goal turns, and
      the harness counts them rather than trusting the model to.

  The hardest direction is the second bullet, and it is where most of these
  assertions point: a completion check that fires on an UNFINISHED goal is the
  failure that ends an autonomous run early with the work undone.

  No provider is reachable in this environment, so the skeptic panel is never
  actually run here — `advance/2` is driven with a synthetic
  `GoalVerifier.Result` exactly as `goal_tracker_test.exs` does. What these
  tests prove is that the model's own tool calls cannot reach `:completed`;
  what they cannot prove is how a real panel votes.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Agent.TaskBrief
  alias OptimalSystemAgent.Tools.Builtins.Goal.Handler

  setup do
    sid = "goal-authoring-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      GoalTracker.reset(sid)
      Steer.drain(sid)
      File.rm(ProgressLedger.path(sid))
      File.rm(TaskBrief.path(sid))
      Application.delete_env(:optimal_system_agent, :goal_blocked_threshold)
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

  defp create(ctx, objective, extra \\ %{}) do
    Handler.execute_create(Map.merge(%{"objective" => objective}, extra), ctx)
  end

  defp update(ctx, status), do: Handler.execute_update(%{"status" => status}, ctx)

  # ── Authoring ───────────────────────────────────────────────────────────

  describe "create_goal — the agent authors its own goal" do
    test "anchors objective and acceptance criteria written by the model", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, msg} =
               create(ctx, "Make the CSV exporter emit RFC-4180 quoting", %{
                 "acceptance_criteria" =>
                   "1. Fields containing commas are double-quoted.\n2. Embedded quotes are doubled.\n3. exporter_test.exs passes."
               })

      assert msg =~ "Goal anchored"

      snap = GoalTracker.snapshot(sid)
      assert snap.status == :active
      assert snap.goal == "Make the CSV exporter emit RFC-4180 quoting"
      assert GoalTracker.goal_loop?(sid)

      # The criteria the MODEL wrote are what got frozen — not an echo of the
      # objective, which is what the pre-port `GOAL:` path produced.
      assert {:ok, brief} = TaskBrief.load(sid)

      assert brief.acceptance_criteria =~ "RFC-4180" or
               brief.acceptance_criteria =~ "double-quoted"

      refute brief.acceptance_criteria == brief.goal
    end

    test "criteria are optional; objective alone still anchors", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Ship the migration")
      assert GoalTracker.snapshot(sid).goal == "Ship the migration"
    end

    test "rejects an empty objective", %{ctx: ctx} do
      assert {:error, _, -32_602} = Handler.validate_create(%{"objective" => "   "}, ctx)
    end
  end

  # ── The freeze ──────────────────────────────────────────────────────────

  describe "the objective is frozen while the goal is live" do
    test "a second create_goal is refused, and the refusal names the live goal", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Rewrite the scheduler to be preemptive")

      assert {:error, msg} = create(ctx, "Add a comment to the scheduler")
      assert msg =~ "unfinished goal"
      assert msg =~ "Rewrite the scheduler to be preemptive"

      # The hard part: the refusal must not have partially applied.
      assert GoalTracker.snapshot(sid).goal == "Rewrite the scheduler to be preemptive"
    end

    test "a refused re-anchor does not reset the run budget or the stall state", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Hard objective")

      GoalTracker.tick_turn(sid)
      GoalTracker.tick_turn(sid)
      GoalTracker.advance(sid, result(:incomplete, gaps: ["lens: missing export"]))

      before = GoalTracker.snapshot(sid)
      assert before.turn_count == 2
      assert before.verify_run_count == 1

      assert {:error, _} = create(ctx, "Easier objective")

      after_ = GoalTracker.snapshot(sid)
      assert after_.turn_count == 2, "a refused re-anchor must not reset turn_count"
      assert after_.verify_run_count == 1, "a refused re-anchor must not refund a run"
      assert after_.goal_id == before.goal_id
      assert after_.last_gap_fingerprint == before.last_gap_fingerprint
    end

    test "a completed goal may be superseded", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "First objective")
      GoalTracker.advance(sid, result(:complete))
      assert GoalTracker.status(sid) == :completed

      assert {:ok, _} = create(ctx, "Second objective")
      assert GoalTracker.snapshot(sid).goal == "Second objective"
      assert GoalTracker.status(sid) == :active
    end

    test "update_goal exposes no parameter that can reach the objective", %{ctx: ctx} do
      params = OptimalSystemAgent.Tools.Builtins.Goal.UpdateTool.parameters()
      assert Map.keys(params["properties"]) == ["status"]

      # `abandoned` was added after this file landed (see `goal_abandon_test.exs`
      # for why, and for what it costs). It is a way to END the live goal, never
      # a way to rewrite it — which is what this test guards, and which the
      # `status`-only property set above still enforces.
      assert params["properties"]["status"]["enum"] == ["complete", "blocked", "abandoned"]

      # And anything outside the enum is refused with Codex's message.
      assert {:error, msg, -32_602} = Handler.validate_update(%{"status" => "active"}, ctx)
      assert msg =~ "complete or blocked"
      assert {:error, _, -32_602} = Handler.validate_update(%{"status" => "paused"}, ctx)
    end
  end

  # ── Completion is a claim, not a verdict ────────────────────────────────

  describe "update_goal(complete) on an UNFINISHED goal" do
    test "does not complete the goal and does not stop the loop", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Unfinished objective")

      assert {:ok, msg} = update(ctx, "complete")
      assert msg =~ "does not end the goal"

      # This is the assertion that matters most in the whole file.
      assert GoalTracker.status(sid) == :active
      refute GoalTracker.completed?(sid)
      assert GoalTracker.continue?(sid), "a claimed-complete goal must keep running"
      assert GoalTracker.goal_loop?(sid)
    end

    test "repeated claims still cannot complete it", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Unfinished objective")

      for _ <- 1..10 do
        assert {:ok, _} = update(ctx, "complete")
      end

      assert GoalTracker.status(sid) == :active
      assert GoalTracker.continue?(sid)
    end

    test "a claim followed by a REFUTING panel leaves the goal active", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Unfinished objective")
      assert {:ok, _} = update(ctx, "complete")

      GoalTracker.advance(sid, result(:incomplete, refuted_count: 2, gaps: ["correctness: stub"]))

      assert GoalTracker.status(sid) == :active
      assert GoalTracker.continue?(sid)
    end

    test "a claim schedules the panel rather than bypassing it", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")

      # Burn a round so the cadence gate would otherwise hold the panel off.
      GoalTracker.advance(sid, result(:incomplete, gaps: ["g"]))
      refute GoalTracker.reverify_due?(sid), "cadence should gate the next round"

      assert {:ok, _} = update(ctx, "complete")
      assert GoalTracker.reverify_due?(sid), "a completion claim must force a panel round"
    end
  end

  describe "update_goal(complete) on a FINISHED goal" do
    test "the panel — and only the panel — completes it", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Finished objective")
      assert {:ok, _} = update(ctx, "complete")

      GoalTracker.advance(sid, result(:complete, refuted_count: 0))

      assert GoalTracker.status(sid) == :completed
      assert GoalTracker.completed?(sid)
      refute GoalTracker.continue?(sid), "a verified goal must stop the loop"
    end

    test "claiming complete is not a precondition for the panel completing it", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Objective")
      GoalTracker.advance(sid, result(:complete))
      assert GoalTracker.status(sid) == :completed
    end
  end

  # ── Blocked: three consecutive turns, counted by the harness ────────────

  describe "update_goal(blocked)" do
    test "the first two claims do not block the goal", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")

      assert {:ok, m1} = update(ctx, "blocked")
      assert m1 =~ "1/3"
      assert GoalTracker.status(sid) == :active
      assert GoalTracker.continue?(sid)

      GoalTracker.tick_turn(sid)
      assert {:ok, m2} = update(ctx, "blocked")
      assert m2 =~ "2/3"
      assert GoalTracker.status(sid) == :active
      assert GoalTracker.continue?(sid), "two blocked claims must not stop an autonomous run"
    end

    test "three consecutive goal turns block it", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")

      assert {:ok, _} = update(ctx, "blocked")
      GoalTracker.tick_turn(sid)
      assert {:ok, _} = update(ctx, "blocked")
      GoalTracker.tick_turn(sid)
      assert {:ok, msg} = update(ctx, "blocked")

      assert msg =~ "blocked"
      assert GoalTracker.status(sid) == :blocked
      assert GoalTracker.blocked?(sid)
      refute GoalTracker.continue?(sid)
    end

    test "repeated claims inside ONE turn cannot ratchet the streak", %{
      session_id: sid,
      ctx: ctx
    } do
      assert {:ok, _} = create(ctx, "Objective")

      for _ <- 1..5 do
        assert {:ok, msg} = update(ctx, "blocked")
        assert msg =~ "1/3", "the streak must count turns, not calls"
      end

      assert GoalTracker.status(sid) == :active
      assert GoalTracker.continue?(sid)
    end

    test "a turn without a claim resets the streak", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")

      assert {:ok, _} = update(ctx, "blocked")
      GoalTracker.tick_turn(sid)
      assert {:ok, m2} = update(ctx, "blocked")
      assert m2 =~ "2/3"

      # Two turns pass with no claim.
      GoalTracker.tick_turn(sid)
      GoalTracker.tick_turn(sid)

      assert {:ok, m3} = update(ctx, "blocked")
      assert m3 =~ "1/3", "a non-consecutive claim must start a fresh streak"
      assert GoalTracker.status(sid) == :active
    end

    test "resuming a blocked goal starts a fresh blocked audit", %{session_id: sid, ctx: ctx} do
      assert {:ok, _} = create(ctx, "Objective")

      for _ <- 1..3 do
        update(ctx, "blocked")
        GoalTracker.tick_turn(sid)
      end

      assert GoalTracker.status(sid) == :blocked

      GoalTracker.resume(sid)
      assert GoalTracker.status(sid) == :active
      assert GoalTracker.snapshot(sid).blocked_claims == 0

      assert {:ok, msg} = update(ctx, "blocked")
      assert msg =~ "1/3", "a resumed goal must not re-block on the first claim"
      assert GoalTracker.status(sid) == :active
    end

    test "a blocked goal reports active: false to the TUI", %{session_id: sid, ctx: ctx} do
      # `5cf0eb0b` replaced the client-side `DONE` sentinel with a structured
      # snapshot whose `active` field the TUI acts on, derived server-side in
      # `tool_routes.ex` as exactly this pair. `:blocked` was added after that
      # landed and satisfies it only by construction — `continue?/1` happens to
      # whitelist `[:active, :off_track]` rather than blacklisting terminals.
      #
      # Pinned here so a future status added to that whitelist, or a
      # blacklist-shaped rewrite of `continue?/1`, breaks loudly instead of
      # quietly letting the TUI drive turns on a blocked goal.
      assert {:ok, _} = create(ctx, "Objective")

      for _ <- 1..3 do
        update(ctx, "blocked")
        GoalTracker.tick_turn(sid)
      end

      assert GoalTracker.status(sid) == :blocked

      # Both conjuncts whitelist `[:active, :off_track]`, so a blocked goal is
      # excluded twice over rather than relying on either one alone.
      refute GoalTracker.goal_loop?(sid)
      refute GoalTracker.continue?(sid)

      refute GoalTracker.goal_loop?(sid) and GoalTracker.continue?(sid),
             "the backend's `active` derivation must be false for a blocked goal"

      # And the live goal it was blocked from is still readable, so the TUI can
      # tell the user WHAT is blocked rather than just that something is.
      assert GoalTracker.snapshot(sid).goal == "Objective"
    end

    test "the threshold is configurable but never below one", %{ctx: ctx, session_id: sid} do
      Application.put_env(:optimal_system_agent, :goal_blocked_threshold, 0)
      assert GoalTracker.blocked_threshold() == 3

      Application.put_env(:optimal_system_agent, :goal_blocked_threshold, 1)
      assert {:ok, _} = create(ctx, "Objective")
      assert {:ok, _} = update(ctx, "blocked")
      assert GoalTracker.status(sid) == :blocked
    end
  end

  # ── No live goal ────────────────────────────────────────────────────────

  describe "with no live goal" do
    test "update_goal reports there is nothing to update", %{ctx: ctx} do
      assert {:error, msg} = update(ctx, "complete")
      assert msg =~ "no live goal"

      assert {:error, msg2} = update(ctx, "blocked")
      assert msg2 =~ "no live goal"
    end

    test "a session-less context cannot anchor or update" do
      assert {:error, msg} = Handler.execute_create(%{"objective" => "x"}, %{})
      assert msg =~ "No session"

      assert {:error, msg2} = Handler.execute_update(%{"status" => "complete"}, %{})
      assert msg2 =~ "No session"
    end
  end
end
