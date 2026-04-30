defmodule OptimalSystemAgent.Agent.EffortTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    Effort.set(:medium)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :effort_level, previous)
      else
        Application.delete_env(:optimal_system_agent, :effort_level)
      end
    end)

    :ok
  end

  test "fast mode uses the low-latency profile" do
    Effort.set(:low)

    assert Effort.fast_mode?()
    assert Effort.thinking_budget() == 0
    assert Effort.max_iterations() == 5
    assert Effort.max_response_tokens() == 2_048
    assert Effort.tool_budget() == 6
  end

  test "toggle_fast switches between low and medium" do
    Effort.set(:medium)

    assert :ok = Effort.toggle_fast()
    assert Effort.current() == :low

    assert :ok = Effort.toggle_fast()
    assert Effort.current() == :medium
  end
end
