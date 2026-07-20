defmodule OptimalSystemAgent.Agent.Loop.ReactLoopGoalVerifierGateTest do
  @moduledoc """
  Smart activation of the goal-verifier skeptic panel, exercised through the
  public `ReactLoop.goal_verifier_enabled?/1` delegation (which forwards to
  `GoalVerifier.activated?/1`).

  Resolution precedence (operator override always wins):

    1. explicit `config goal_verifier_enabled: true | false` — verbatim.
    2. `:auto` (default) — ON for autonomous/long-running work (overdrive/
       bypass mode, an anchored goal loop, or a turn past the activation
       iteration threshold), OFF for short interactive turns.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.PermissionMode

  setup do
    original = Application.get_env(:optimal_system_agent, :goal_verifier_enabled, :auto)

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, original)
      Application.delete_env(:optimal_system_agent, :goal_verifier_activate_after_iterations)
    end)

    :ok
  end

  defp unique_session_id do
    "gv-gate-#{:erlang.unique_integer([:positive])}"
  end

  describe "goal_verifier_enabled?/1 — :auto (default) smart activation" do
    test "OFF for a short interactive ask-mode turn" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      refute ReactLoop.goal_verifier_enabled?(%{})
      refute ReactLoop.goal_verifier_enabled?(%{iteration: 2, permission_mode: :ask})
    end

    test "ON under overdrive mode" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :overdrive)

      assert ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end

    test "ON under bypass mode" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :bypass)

      assert ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end

    test "ON via the live state permission_mode without a sticky store entry" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      assert ReactLoop.goal_verifier_enabled?(%{permission_mode: :overdrive})
    end

    test "ON once a turn passes the activation iteration threshold, even in ask mode" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      Application.put_env(:optimal_system_agent, :goal_verifier_activate_after_iterations, 12)

      refute ReactLoop.goal_verifier_enabled?(%{iteration: 11, permission_mode: :ask})
      assert ReactLoop.goal_verifier_enabled?(%{iteration: 12, permission_mode: :ask})
    end

    test "ON when driving an anchored goal loop, even in ask mode" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, :auto)
      session_id = unique_session_id()
      GoalTracker.start(session_id, "ship the exporter")

      assert ReactLoop.goal_verifier_enabled?(%{session_id: session_id, permission_mode: :ask})

      GoalTracker.reset(session_id)
    end
  end

  describe "goal_verifier_enabled?/1 — explicit config override wins both ways" do
    test "explicit false forces OFF even under overdrive" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, false)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :overdrive)

      refute ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end

    test "explicit true forces ON even for a short ask-mode turn" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :ask)

      assert ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end

    test "explicit true stays ON under overdrive too" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :overdrive)

      assert ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end
  end
end
