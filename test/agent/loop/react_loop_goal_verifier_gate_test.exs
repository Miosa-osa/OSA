defmodule OptimalSystemAgent.Agent.Loop.ReactLoopGoalVerifierGateTest do
  @moduledoc """
  Regression test for finding #4: the goal-verifier skeptic panel must stay
  OFF by default, including under `:overdrive`/`:bypass` — the operator's
  PRIMARY autonomous mode. It previously auto-enabled there, contradicting
  the "off by default" moduledoc and spawning N subagent skeptics per
  write-completion on the operator's main path.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.PermissionMode

  setup do
    original = Application.get_env(:optimal_system_agent, :goal_verifier_enabled, false)

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, original)
    end)

    :ok
  end

  defp unique_session_id do
    "gv-gate-#{:erlang.unique_integer([:positive])}"
  end

  describe "goal_verifier_enabled?/1" do
    test "off by default with no config and no session_id" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, false)
      refute ReactLoop.goal_verifier_enabled?(%{})
    end

    test "off under overdrive mode — the regression (finding #4)" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, false)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :overdrive)

      refute ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end

    test "off under bypass mode — the regression (finding #4)" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, false)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :bypass)

      refute ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end

    test "on when explicitly opted in via config, even in ask mode" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :ask)

      assert ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end

    test "on under overdrive too, once explicitly opted in" do
      Application.put_env(:optimal_system_agent, :goal_verifier_enabled, true)
      session_id = unique_session_id()
      PermissionMode.put(session_id, :overdrive)

      assert ReactLoop.goal_verifier_enabled?(%{session_id: session_id})

      PermissionMode.clear(session_id)
    end
  end
end
