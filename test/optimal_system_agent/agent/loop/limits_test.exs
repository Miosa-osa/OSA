defmodule OptimalSystemAgent.Agent.Loop.LimitsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.Limits

  defp state(overrides) do
    Map.merge(
      %{
        session_id: "limits-test",
        max_budget_usd: nil,
        max_turns: nil,
        turn_count: 0,
        session_cost_usd: 0.0
      },
      Map.new(overrides)
    )
  end

  describe "check/1 — budget cap (previously a dead check)" do
    test "no cap set => never blocks (long runs are not killed)" do
      assert Limits.check(state(session_cost_usd: 9_999.0)) == nil
    end

    test "under budget => passes" do
      assert Limits.check(state(max_budget_usd: 5.0, session_cost_usd: 4.99)) == nil
    end

    test "spend at/over cap => real error string (the cap now bites)" do
      result = Limits.check(state(max_budget_usd: 5.0, session_cost_usd: 5.0))
      assert is_binary(result)
      assert result =~ "Budget limit reached"
    end

    test "budget takes precedence over turns" do
      result =
        Limits.check(
          state(max_budget_usd: 1.0, session_cost_usd: 2.0, max_turns: 1, turn_count: 5)
        )

      assert result =~ "Budget limit reached"
    end
  end

  describe "check/1 — turn cap" do
    test "no cap => never blocks" do
      assert Limits.check(state(turn_count: 1_000_000)) == nil
    end

    test "over turn cap => error" do
      result = Limits.check(state(max_turns: 3, turn_count: 4))
      assert result =~ "Turn limit reached"
    end

    test "at turn cap => still allowed (strict greater-than)" do
      assert Limits.check(state(max_turns: 3, turn_count: 3)) == nil
    end
  end

  describe "budget_exceeded?/1" do
    test "false when no cap" do
      refute Limits.budget_exceeded?(state(session_cost_usd: 100.0))
    end

    test "true when spend reaches cap" do
      assert Limits.budget_exceeded?(state(max_budget_usd: 2.0, session_cost_usd: 2.5))
    end

    test "false when under cap" do
      refute Limits.budget_exceeded?(state(max_budget_usd: 2.0, session_cost_usd: 1.0))
    end
  end
end
