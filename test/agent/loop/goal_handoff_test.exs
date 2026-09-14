defmodule OptimalSystemAgent.Agent.Loop.GoalHandoffTest do
  use ExUnit.Case, async: false
  use Plug.Test
  alias OptimalSystemAgent.Agent.Loop.{GoalTracker, GoalVerifier, ReactLoop}
  alias OptimalSystemAgent.Tools.Builtins.Goal.Handler
  alias OptimalSystemAgent.Tools.UseContext

  test "read-only final-output triage waits instead of generating another turn", %{
    sid: sid,
    request: r
  } do
    previous = Application.get_env(:optimal_system_agent, :goal_verifier_triage_runner)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_system_agent, :goal_verifier_triage_runner, previous),
        else: Application.delete_env(:optimal_system_agent, :goal_verifier_triage_runner)
    end)

    Application.put_env(:optimal_system_agent, :goal_verifier_triage_runner, fn _ ->
      {:ok, Jason.encode!(Map.put(r, "status", "awaiting_user"))}
    end)

    state = %{session_id: sid, goal_mode: true, messages: []}
    GoalVerifier.maybe_wait_for_user(state, "Draft is ready; please review.")
    assert GoalTracker.awaiting_user?(sid)
    assert GoalVerifier.skip_reason(state) == :goal_inactive
    refute ReactLoop.goal_continue_due?(state)
  end

  # `maybe_wait_for_user/2` spends a real triage round-trip on the same provider
  # that just drove the turn, so it has to answer to the same operator switch
  # and the same per-turn spend counters as `maybe_gate/1`. Ungated it fired on
  # every tool-call-free generation inside a goal turn: an anchored goal with a
  # 3-continuation budget bought 8 provider round-trips instead of 4, and an
  # explicit `goal_verifier_enabled: false` — the setting whose whole job is to
  # buy silence from this module — stopped none of them.
  test "the handoff triage answers to the verifier switch and its spend guards", %{
    sid: sid,
    request: r
  } do
    keys = [:goal_verifier_enabled, :goal_verifier_triage_runner]
    previous = Map.new(keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end
    end)

    parent = self()

    Application.put_env(:optimal_system_agent, :goal_verifier_triage_runner, fn _ ->
      send(parent, :triaged)
      {:ok, Jason.encode!(Map.put(r, "status", "awaiting_user"))}
    end)

    state = %{session_id: sid, goal_mode: true, messages: []}

    Application.put_env(:optimal_system_agent, :goal_verifier_enabled, false)
    GoalVerifier.maybe_wait_for_user(state, "Draft is ready; please review.")

    refute_received :triaged,
                    "an explicit goal_verifier_enabled: false must buy silence on this path too"

    Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)

    # The per-turn run cap (3) and the stall early-exit (2) are budget guards,
    # not size heuristics — unlike `:no_work`/`:trivial`, which this path exists
    # to bypass for goals that write nothing.
    GoalVerifier.maybe_wait_for_user(Map.put(state, :goal_verifier_runs, 3), "Draft is ready.")
    refute_received :triaged, "the per-turn verification run cap must bound the triage too"

    GoalVerifier.maybe_wait_for_user(
      Map.put(state, :goal_verifier_stall_count, 2),
      "Draft is ready."
    )

    refute_received :triaged, "a stalled goal must not keep paying for triage"

    # And with every guard satisfied it still does its job.
    GoalVerifier.maybe_wait_for_user(state, "Draft is ready; please review.")
    assert_received :triaged
    assert GoalTracker.awaiting_user?(sid)
  end

  # The handoff clause in `ReactLoop.handle_result/3` returns the waiting notice
  # INSTEAD of the answer, and `Loop.run_and_reply/1` records only the returned
  # string as the turn's assistant message. So the answer the user watched
  # stream — the very artifact they are being asked to approve — has to be put
  # into the transcript by the halting clause itself, or it is lost from
  # history, from the persisted session, and from the context the model resumes
  # with after `/goal approve`.
  test "the answer that triggered the handoff stays in history", %{sid: sid, request: r} do
    keys = [
      :default_provider,
      :mock_provider_final_text,
      :max_iterations,
      :goal_verifier_enabled,
      :goal_verifier_triage_runner,
      :proactive_compaction_enabled
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end
    end)

    answer = "Draft v1 is at thesis.md — the argument now runs from the survey data."

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_final_text, answer)
    Application.put_env(:optimal_system_agent, :max_iterations, 12)
    Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
    Application.put_env(:optimal_system_agent, :proactive_compaction_enabled, false)

    Application.put_env(:optimal_system_agent, :goal_verifier_triage_runner, fn _ ->
      {:ok, Jason.encode!(Map.put(r, "status", "awaiting_user"))}
    end)

    state =
      Map.from_struct(%OptimalSystemAgent.Agent.Loop{
        session_id: sid,
        provider: :mock,
        model: "mock-model-1.0",
        iteration: 0,
        auto_continues: 0,
        messages: [%{role: "user", content: "draft the thesis"}],
        tools: [],
        permission_mode: :ask,
        permission_tier: :full,
        working_dir: File.cwd!()
      })

    OptimalSystemAgent.Test.MockProvider.reset_round_trips()
    {reply, final} = ReactLoop.run(state)

    assert GoalTracker.awaiting_user?(sid)
    assert reply =~ "Waiting for your decision"

    assert Enum.any?(final.messages, &(&1[:role] == "assistant" and &1[:content] == answer)),
           "the handoff halted on the waiting notice and left the model's own answer out " <>
             "of the transcript: #{inspect(final.messages)}"

    assert OptimalSystemAgent.Test.MockProvider.round_trips() == 1,
           "handing off to the user must cost exactly the one generation the user read"
  end

  test "HTTP commands expose pending decision and clear leaves no active goal", %{
    sid: sid,
    request: r
  } do
    alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes
    {:ok, waiting} = GoalTracker.request_decision(sid, r)

    execute = fn command ->
      conn(:post, "/execute", Jason.encode!(%{command: command, session_id: sid}))
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      |> ToolRoutes.call(ToolRoutes.init([]))
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
    end

    status = execute.("goal")
    assert status["goal"]["active"] == false, inspect(status)

    assert status["goal"]["pending_decision"]["request_id"] ==
             waiting.pending_decision["request_id"]

    assert status["output"] =~ "/goal approve"
    assert execute.("goal cancel")["goal"]["status"] == "cleared"
    assert OptimalSystemAgent.Agent.TaskBrief.context_block(sid) == nil
    {:ok, recap} = OptimalSystemAgent.Agent.ProgressLedger.summarize(sid)
    assert recap =~ "Goal status: cleared"
  end

  setup do
    sid = "handoff-#{System.unique_integer([:positive])}"

    GoalTracker.start(sid, "Draft thesis for Steven's approval",
      token_budget: 9000,
      tokens_used: 100
    )

    on_exit(fn -> GoalTracker.reset(sid) end)

    %{
      sid: sid,
      request: %{
        "question" => "Approve draft v1?",
        "criterion" => "Steven approves thesis",
        "work_summary" => "Draft complete; approval missing",
        "artifact" => "thesis.md revision v1"
      }
    }
  end

  test "approved read-only goal completes only after a successful panel", %{sid: sid, request: r} do
    keys = [:goal_verifier_triage_runner, :goal_verifier_panel_runner]
    previous = Map.new(keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end
    end)

    {:ok, waiting} = GoalTracker.request_decision(sid, r)

    {:ok, _} =
      GoalTracker.resolve_decision(sid, waiting.pending_decision["request_id"], "approve")

    assert GoalTracker.status(sid) == :active

    Application.put_env(:optimal_system_agent, :goal_verifier_triage_runner, fn _ ->
      {:ok, ~s({"status":"candidate_complete"})}
    end)

    parent = self()

    Application.put_env(:optimal_system_agent, :goal_verifier_panel_runner, fn _, configs ->
      send(parent, {:reviewed, configs})

      Enum.map(configs, fn _ ->
        {:ok, ~s({"refuted":false,"off_track":false,"reason":"Reviewed draft and approval"})}
      end)
    end)

    state = %{session_id: sid, goal_mode: true, messages: [], working_dir: File.cwd!()}
    GoalVerifier.maybe_wait_for_user(state, "THE ACTUAL THESIS DELIVERABLE")
    assert_receive {:reviewed, configs}
    assert Enum.all?(configs, &String.contains?(&1.task, "THE ACTUAL THESIS DELIVERABLE"))
    assert Enum.all?(configs, &String.contains?(&1.task, "approve"))
    assert GoalTracker.status(sid) == :completed
  end

  test "waiting stops continuation and verification without completing or replacing goal", %{
    sid: sid,
    request: r
  } do
    {:ok, snap} = GoalTracker.request_decision(sid, r)
    assert snap.status == :awaiting_user

    # `iteration: 1`, not `0`: this halt is for the model's OWN mid-turn
    # continuation past the decision it just asked for (a turn already past
    # its first model call), never for a brand-new top-level turn — that
    # would swallow a genuine user message too (see
    # "a fresh top-level turn ... reaches the model instead of being
    # swallowed" below, and the `iter > 0` guard in `ReactLoop.run/1`).
    {reply, _state} = ReactLoop.run(%{session_id: sid, iteration: 1, messages: []})
    assert reply =~ "Waiting for your decision"
    assert reply =~ snap.pending_decision["request_id"]
    refute GoalTracker.continue?(sid)
    refute GoalTracker.reverify_due?(sid)
    refute ReactLoop.goal_continue_due?(%{session_id: sid})
    assert {:error, {:goal_active, _}} = GoalTracker.anchor_new(sid, "easier objective")
    assert {:error, :not_live} = GoalTracker.claim_complete(sid)
    assert GoalTracker.resume(sid).status == :awaiting_user
  end

  # Reported live: an anchored goal asked a decision question, and every
  # ordinary message the user typed afterward — not `/goal approve` or
  # `/goal reject`, just normal chat — came back with nothing but the same
  # static "waiting for your decision" notice, with no way to redirect the
  # agent short of clearing the goal outright. The old guard halted on
  # `GoalTracker.awaiting_user?(sid)` alone, with no `iteration` check, so it
  # caught brand-new top-level turns exactly as readily as the model's own
  # mid-turn continuation.
  test "a fresh top-level turn while awaiting a decision reaches the model instead of being swallowed",
       %{sid: sid, request: r} do
    keys = [:default_provider, :mock_provider_final_text, :max_iterations]
    previous = Map.new(keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
          :error -> Application.delete_env(:optimal_system_agent, key)
        end
      end
    end)

    {:ok, snap} = GoalTracker.request_decision(sid, r)
    assert snap.status == :awaiting_user

    answer = "Go ahead and treat both PRs as pre-approved — merge them."
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_final_text, answer)
    Application.put_env(:optimal_system_agent, :max_iterations, 12)

    state =
      Map.from_struct(%OptimalSystemAgent.Agent.Loop{
        session_id: sid,
        provider: :mock,
        model: "mock-model-1.0",
        iteration: 0,
        auto_continues: 0,
        messages: [%{role: "user", content: "just merge them, I trust you"}],
        tools: [],
        permission_mode: :ask,
        permission_tier: :full,
        working_dir: File.cwd!()
      })

    OptimalSystemAgent.Test.MockProvider.reset_round_trips()
    {reply, _final} = ReactLoop.run(state)

    refute reply =~ "Waiting for your decision",
           "a genuine new user message must reach the model, not be swallowed by the pending " <>
             "decision halt"

    assert reply == answer
    assert OptimalSystemAgent.Test.MockProvider.round_trips() == 1

    # The decision is still exactly as pending as before — a chat reply is
    # not `/goal approve`/`/goal reject`, so it must not silently resolve it.
    assert GoalTracker.awaiting_user?(sid)
  end

  test "request, budget and approval survive cache loss", %{sid: sid, request: r} do
    {:ok, snap} = GoalTracker.request_decision(sid, r)
    :ets.delete(:osa_goal_tracker, sid)
    restored = GoalTracker.snapshot(sid)
    assert restored.pending_decision == snap.pending_decision
    assert restored.token_budget == 9000
    assert restored.tokens_at_start == 100
    id = restored.pending_decision["request_id"]

    assert {:error, :stale_or_missing_request} =
             GoalTracker.resolve_decision(sid, "hello", "approve")

    assert {:ok, active} = GoalTracker.resolve_decision(sid, id, "approve")
    assert active.status == :active
    assert active.token_budget == 9000

    assert [%{"decision" => "approve", "artifact" => "thesis.md revision v1"}] =
             active.decision_history

    assert {:error, :stale_or_missing_request} = GoalTracker.resolve_decision(sid, id, "approve")
    :ets.delete(:osa_goal_tracker, sid)
    assert GoalTracker.snapshot(sid).decision_history == active.decision_history
  end

  test "clear persists and late verifier cannot resurrect it", %{sid: sid, request: r} do
    token = GoalTracker.verification_token(sid)
    {:ok, waiting} = GoalTracker.request_decision(sid, r)
    assert {:ok, %{status: :cleared}} = GoalTracker.clear(sid)
    :ets.delete(:osa_goal_tracker, sid)
    assert GoalTracker.snapshot(sid).status == :cleared
    assert GoalTracker.resume(sid).status == :cleared
    result = %GoalVerifier.Result{verdict: :complete}
    assert {:error, :stale_verification} = GoalTracker.advance_if_current(sid, token, result, 20)

    assert {:error, :stale_or_missing_request} =
             GoalTracker.resolve_decision(sid, waiting.pending_decision["request_id"], "approve")

    assert {:ok, _} = GoalTracker.anchor_new(sid, "A genuinely new task")
    assert OptimalSystemAgent.Agent.TaskBrief.context_block(sid) =~ "A genuinely new task"
    refute OptimalSystemAgent.Agent.TaskBrief.context_block(sid) =~ "Draft thesis"
    assert {:error, :stale_verification} = GoalTracker.advance_if_current(sid, token, result, 20)
  end

  test "manual pause invalidates a running review", %{sid: sid} do
    token = GoalTracker.verification_token(sid)
    GoalTracker.pause(sid)

    assert {:error, :stale_verification} =
             GoalTracker.advance_if_current(
               sid,
               token,
               %GoalVerifier.Result{verdict: :incomplete},
               999
             )

    assert GoalTracker.snapshot(sid).status == :paused
  end

  test "reject is not approve and duplicate requests do not reset counters", %{
    sid: sid,
    request: r
  } do
    {:ok, a} = GoalTracker.request_decision(sid, r)
    {:ok, b} = GoalTracker.request_decision(sid, r)
    assert a.pending_decision == b.pending_decision

    assert {:error, :pending_decision_exists} =
             GoalTracker.request_decision(sid, Map.put(r, "artifact", "revision v2"))

    {:ok, snap} =
      GoalTracker.resolve_decision(
        sid,
        a.pending_decision["request_id"],
        "reject",
        "Fix introduction"
      )

    assert [%{"decision" => "reject", "note" => "Fix introduction"}] = snap.decision_history
    assert snap.status != :completed
  end

  test "invalid requests and control-word objectives are refused", %{sid: sid} do
    assert {:error, :invalid_decision_request} = GoalTracker.request_decision(sid, %{})
    ctx = UseContext.empty()
    assert {:error, _, _} = Handler.validate_create(%{"objective" => "end"}, ctx)
    assert {:ok, _} = Handler.validate_create(%{"objective" => "Refactor"}, ctx)
    assert {:error, _, _} = Handler.validate_update(%{"status" => "awaiting_user"}, ctx)
    assert {:error, _, _} = Handler.validate_update(%{"status" => "approve"}, ctx)
  end

  # ── resolve_decision/4 with request_id: nil — no id required ─────────────
  #
  # A session has at most one pending decision (`pending_decision` is a single
  # map, not a list), so making the caller also supply its id back was pure
  # ceremony. `nil` resolves WHATEVER is currently pending.
  describe "resolve_decision/4 with a nil request_id" do
    test "resolves the current pending decision with no id at all", %{sid: sid, request: r} do
      {:ok, waiting} = GoalTracker.request_decision(sid, r)
      assert waiting.status == :awaiting_user

      assert {:ok, resolved} = GoalTracker.resolve_decision(sid, nil, "approve")
      assert resolved.status == :active
      assert [%{"decision" => "approve"}] = resolved.decision_history
    end

    test "carries notes through exactly like the explicit-id path", %{sid: sid, request: r} do
      {:ok, _} = GoalTracker.request_decision(sid, r)

      assert {:ok, resolved} = GoalTracker.resolve_decision(sid, nil, "reject", "needs a redo")
      assert [%{"decision" => "reject", "note" => "needs a redo"}] = resolved.decision_history
    end

    test "with nothing pending, fails with a distinct, honest error", %{sid: sid} do
      refute GoalTracker.awaiting_user?(sid)
      assert {:error, :no_pending_decision} = GoalTracker.resolve_decision(sid, nil, "approve")
    end

    test "a nil id never resolves a decision meant for a DIFFERENT session", %{
      sid: sid,
      request: r
    } do
      other_sid = "handoff-other-#{System.unique_integer([:positive])}"
      GoalTracker.start(other_sid, "a completely unrelated objective")
      {:ok, _} = GoalTracker.request_decision(other_sid, r)

      # This session has nothing pending of its own.
      assert {:error, :no_pending_decision} = GoalTracker.resolve_decision(sid, nil, "approve")
      # The other session's decision is untouched.
      assert GoalTracker.awaiting_user?(other_sid)

      GoalTracker.reset(other_sid)
    end
  end
end
