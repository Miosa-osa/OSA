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
    {reply, _state} = ReactLoop.run(%{session_id: sid, iteration: 0, messages: []})
    assert reply =~ "Waiting for your decision"
    assert reply =~ snap.pending_decision["request_id"]
    refute GoalTracker.continue?(sid)
    refute GoalTracker.reverify_due?(sid)
    refute ReactLoop.goal_continue_due?(%{session_id: sid})
    assert {:error, {:goal_active, _}} = GoalTracker.anchor_new(sid, "easier objective")
    assert {:error, :not_live} = GoalTracker.claim_complete(sid)
    assert GoalTracker.resume(sid).status == :awaiting_user
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
end
