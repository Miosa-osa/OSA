defmodule OptimalSystemAgent.Orchestrator.SubagentStoppingDisciplineTest do
  @moduledoc """
  Subagent stopping discipline (items 6-8).

  A high turn cap (elite 120) is only safe if a subagent cannot run away in
  cost OR in per-turn tool volume, and a cap-hit must be a RESUMABLE PARTIAL
  the parent can continue - not a dead FAILED that invites redoing the work.

    * Item 7 - a subagent gets a sane per-turn tool-call ceiling instead of
      falling back to the effectively-unbounded global default.
    * Item 8 - a turn/budget cap surfaces as a resumable partial with the
      agent id as the resume handle, classified apart from real failures.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Orchestrator

  describe "per-turn tool ceiling (item 7)" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :subagent_max_tool_calls_per_turn)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:optimal_system_agent, :subagent_max_tool_calls_per_turn)
          v -> Application.put_env(:optimal_system_agent, :subagent_max_tool_calls_per_turn, v)
        end
      end)

      :ok
    end

    test "defaults to a bounded, positive value (not unbounded)" do
      Application.delete_env(:optimal_system_agent, :subagent_max_tool_calls_per_turn)

      ceiling = Orchestrator.subagent_per_turn_tool_ceiling()
      assert is_integer(ceiling)
      assert ceiling == 50
    end

    test "is overridable via config" do
      Application.put_env(:optimal_system_agent, :subagent_max_tool_calls_per_turn, 12)
      assert Orchestrator.subagent_per_turn_tool_ceiling() == 12
    end

    test "ignores a non-positive / bad override and keeps the default" do
      Application.put_env(:optimal_system_agent, :subagent_max_tool_calls_per_turn, 0)
      assert Orchestrator.subagent_per_turn_tool_ceiling() == 50

      Application.put_env(:optimal_system_agent, :subagent_max_tool_calls_per_turn, "nope")
      assert Orchestrator.subagent_per_turn_tool_ceiling() == 50
    end
  end

  describe "cap-hit classification (item 8)" do
    test "a turn-limit error is a resumable cap, not a failure" do
      assert Orchestrator.resumable_cap_reason?("Turn limit reached (13/12)")
    end

    test "a budget-limit error is a resumable cap" do
      assert Orchestrator.resumable_cap_reason?("Budget limit reached ($8.01 / $8.0)")
    end

    test "a genuine fault is NOT a resumable cap" do
      refute Orchestrator.resumable_cap_reason?("boom: connection refused")
      refute Orchestrator.resumable_cap_reason?(:timeout)
      refute Orchestrator.resumable_cap_reason?({:crashed, :killed})
    end
  end

  describe "resumable partial message (item 8)" do
    test "leads with the resume affordance and names the resume handle + cap" do
      msg =
        Orchestrator.resumable_partial_message(
          "researcher",
          "Turn limit reached (61/60)",
          "Got through 40 of the pages.",
          "agent:parent-1:researcher"
        )

      # Marked PARTIAL up front so the run never reads as finished.
      assert String.starts_with?(msg, "PARTIAL")
      # Names the exact cap that stopped it, so the parent knows why.
      assert msg =~ "Turn limit reached (61/60)"
      # The contract: resume via SendMessage to the agent id.
      assert msg =~ "resume with SendMessage"
      assert msg =~ "agent:parent-1:researcher"
      # Tells the parent NOT to redo the work.
      assert msg =~ "do NOT restart"
      # Carries the child's progress.
      assert msg =~ "Got through 40 of the pages."
    end

    test "degrades gracefully when the child left no closing text" do
      msg =
        Orchestrator.resumable_partial_message(
          "coder",
          "Budget limit reached ($4.02 / $4.0)",
          nil,
          "agent:p:coder"
        )

      assert String.starts_with?(msg, "PARTIAL")
      assert msg =~ "resume with SendMessage"
      assert msg =~ "transcript"
      refute msg =~ "Progress so far:"
    end
  end
end
