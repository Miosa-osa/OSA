defmodule OptimalSystemAgent.Agent.Loop.LimitsSubagentPainTest do
  @moduledoc """
  VSM item 9 — a subagent (a Loop state carrying `:parent_session_id`)
  reports its OWN budget pressure to its parent as a structured
  `SubagentPain` event, at 80% ("approaching", advisory) and at/over 100%
  ("exceeded", the turn is actually blocked).

  A top-level session (no `:parent_session_id`) has nothing to report to, and
  must not raise or otherwise misbehave for lacking one.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Limits
  alias OptimalSystemAgent.Agent.SubagentPain

  setup do
    SubagentPain.reset_dedupe()
    :ok
  end

  defp state(overrides) do
    Map.merge(
      %{
        session_id: "limits-pain-test",
        parent_session_id: nil,
        max_budget_usd: nil,
        max_turns: nil,
        turn_count: 0,
        session_cost_usd: 0.0
      },
      Map.new(overrides)
    )
  end

  describe "a top-level session (no parent) has nothing to report to" do
    test "check/1 still enforces the cap without raising" do
      parent = "limits-pain-parent-" <> Integer.to_string(System.unique_integer([:positive]))
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")

      result = Limits.check(state(max_budget_usd: 1.0, session_cost_usd: 1.5))
      assert result =~ "Budget limit reached"

      refute_receive {:osa_event, %{type: :subagent_pain}}, 100
    end
  end

  describe "a subagent (carries :parent_session_id) escalates budget pain to its parent" do
    test "approaching the cap (>= 80%) reports :budget_approaching/:warning without blocking the turn" do
      parent = "limits-pain-parent-" <> Integer.to_string(System.unique_integer([:positive]))
      child = "limits-pain-child-" <> Integer.to_string(System.unique_integer([:positive]))
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")

      result =
        Limits.check(
          state(
            session_id: child,
            parent_session_id: parent,
            max_budget_usd: 4.0,
            session_cost_usd: 3.3
          )
        )

      assert result == nil, "approaching the cap must NOT itself block the turn"

      assert_receive {:osa_event,
                      %{
                        type: :subagent_pain,
                        session_id: ^parent,
                        agent_id: ^child,
                        cause: :budget_approaching,
                        severity: :warning
                      }},
                     1_000
    end

    test "at/over the cap reports :budget_exceeded/:critical AND blocks the turn" do
      parent = "limits-pain-parent-" <> Integer.to_string(System.unique_integer([:positive]))
      child = "limits-pain-child-" <> Integer.to_string(System.unique_integer([:positive]))
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")

      result =
        Limits.check(
          state(
            session_id: child,
            parent_session_id: parent,
            max_budget_usd: 4.0,
            session_cost_usd: 4.5
          )
        )

      assert result =~ "Budget limit reached"

      assert_receive {:osa_event,
                      %{
                        type: :subagent_pain,
                        session_id: ^parent,
                        agent_id: ^child,
                        cause: :budget_exceeded,
                        severity: :critical
                      }},
                     1_000
    end

    test "comfortably under the cap reports nothing" do
      parent = "limits-pain-parent-" <> Integer.to_string(System.unique_integer([:positive]))
      child = "limits-pain-child-" <> Integer.to_string(System.unique_integer([:positive]))
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{parent}")

      assert Limits.check(
               state(
                 session_id: child,
                 parent_session_id: parent,
                 max_budget_usd: 4.0,
                 session_cost_usd: 1.0
               )
             ) == nil

      refute_receive {:osa_event, %{type: :subagent_pain}}, 100
    end
  end
end
