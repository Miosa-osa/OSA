defmodule OptimalSystemAgent.Agent.EffortCeilingTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Effort

  test "default medium effort allows a CC-like iteration ceiling (not the old 30)" do
    assert Effort.get(:medium).max_iterations >= 100
  end

  test "low/high/max ceilings are backstops, not routine caps" do
    assert Effort.get(:low).max_iterations >= 50
    assert Effort.get(:high).max_iterations >= 150
    assert Effort.get(:max).max_iterations >= 2000
  end
end
