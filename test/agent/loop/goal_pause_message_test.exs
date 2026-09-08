defmodule OptimalSystemAgent.Agent.Loop.GoalPauseMessageTest do
  @moduledoc """
  A goal-paused turn must say WHY it is paused, not always claim a stall.

  Reported: a fresh turn that walks into `GoalTracker.paused?/1 == true` with
  `pause_reason: :user` (a manual `/goal pause`, or the TUI's own
  interrupt-driven pause) got the SAME hardcoded halt text as a genuine stall
  — "no measurable progress across turns" — which is self-contradictory when
  a human paused it, and equally wrong for `:run_cap` / `:usage_limits`,
  neither of which is a stall either.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.ReactLoop

  defp sid, do: "goal-pause-msg-#{System.unique_integer([:positive])}"

  defp base_state(session_id) do
    %{
      session_id: session_id,
      iteration: 0,
      messages: [%{role: "user", content: "keep going"}]
    }
  end

  setup do
    prev = Application.fetch_env(:optimal_system_agent, :goal_tracker_enabled)
    # Force the tracker on regardless of autonomous posture — a `:paused`
    # goal is (by design) no longer a `goal_loop?/1`, so `:auto` resolution
    # would skip the very branch under test.
    Application.put_env(:optimal_system_agent, :goal_tracker_enabled, true)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :goal_tracker_enabled, v)
        :error -> Application.delete_env(:optimal_system_agent, :goal_tracker_enabled)
      end
    end)

    :ok
  end

  describe "the halt message names the actual pause reason" do
    test "a genuine stall says so" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :no_progress)

      {message, _state} = ReactLoop.run(base_state(s))
      assert message =~ "no measurable progress"

      GoalTracker.reset(s)
    end

    test "a manual/user pause does not claim a stall" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :user)

      {message, _state} = ReactLoop.run(base_state(s))

      refute message =~ "no measurable progress",
             "a user-initiated pause must not be reported as a stall: #{message}"

      assert message =~ "not a stall"

      GoalTracker.reset(s)
    end

    test "a spent lifetime verification-run cap says so, not a stall" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :run_cap)

      {message, _state} = ReactLoop.run(base_state(s))
      refute message =~ "no measurable progress"
      assert message =~ "verification-run cap"

      GoalTracker.reset(s)
    end

    test "a spent token budget says so, not a stall" do
      s = sid()
      GoalTracker.start(s, "ship the exporter")
      GoalTracker.pause(s, :usage_limits)

      {message, _state} = ReactLoop.run(base_state(s))
      refute message =~ "no measurable progress"
      assert message =~ "token budget"

      GoalTracker.reset(s)
    end
  end
end
