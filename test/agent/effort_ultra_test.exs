defmodule OptimalSystemAgent.Agent.EffortUltraTest do
  @moduledoc """
  The `:ultra` effort tier (OSA's `ultracode`) + the effort-ladder rank helpers
  that gate dynamic-workflow fan-out.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    previous_session = session_effort_level()
    Effort.set(:medium)

    on_exit(fn ->
      restore_session_effort_level(previous_session)

      if previous do
        Application.put_env(:optimal_system_agent, :effort_level, previous)
      else
        Application.delete_env(:optimal_system_agent, :effort_level)
      end
    end)

    :ok
  end

  test "ultra is a real level above max" do
    ultra = Effort.get(:ultra)
    max = Effort.get(:max)

    assert ultra.label == "Ultra"
    assert ultra.description =~ "dynamic workflows"
    assert ultra.thinking_budget == 64_000
    assert ultra.thinking_budget > max.thinking_budget
    assert ultra.max_iterations >= 4000
    assert ultra.max_iterations > max.max_iterations
    assert ultra.tool_budget >= max.tool_budget
  end

  test "levels/0 lists ultra highest" do
    assert Effort.levels() == [:low, :medium, :high, :max, :ultra]
    assert List.last(Effort.levels()) == :ultra
  end

  test "rank orders low < medium < high < max < ultra" do
    ranks = Enum.map([:low, :medium, :high, :max, :ultra], &Effort.rank/1)
    assert ranks == Enum.sort(ranks)
    assert Effort.rank(:ultra) > Effort.rank(:max)
    assert Effort.rank(:bogus) == -1
  end

  test "at_least?/2 and current_at_least?/1 gate on the ladder" do
    assert Effort.at_least?(:ultra, :ultra)
    assert Effort.at_least?(:ultra, :max)
    refute Effort.at_least?(:max, :ultra)
    refute Effort.at_least?(:high, :ultra)

    Effort.set(:ultra)
    assert Effort.current() == :ultra
    assert Effort.current_at_least?(:ultra)

    Effort.set(:max)
    refute Effort.current_at_least?(:ultra)
    assert Effort.current_at_least?(:max)
  end

  test "set/1 accepts ultra and drives the ultra budgets" do
    assert :ok = Effort.set(:ultra)
    assert Effort.current() == :ultra
    assert Effort.thinking_budget() == 64_000
    assert Effort.max_iterations() >= 4000
  end

  defp session_effort_level do
    case :ets.whereis(:osa_settings) do
      :undefined ->
        :missing

      _ ->
        case :ets.lookup(:osa_settings, {:session, :effort_level}) do
          [{{:session, :effort_level}, value}] -> {:value, value}
          _ -> :missing
        end
    end
  end

  defp restore_session_effort_level(:missing) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.delete(:osa_settings, {:session, :effort_level})
    end
  end

  defp restore_session_effort_level({:value, value}) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.insert(:osa_settings, {{:session, :effort_level}, value})
    end
  end
end
