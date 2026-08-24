defmodule OptimalSystemAgent.Tools.Builtins.OrchestrateTest do
  @moduledoc """
  The orchestrate tool now advertises a speed/cost `priority` that it threads
  into `Swarm.Patterns.dispatch`, so every spawned config carries it and
  DelegationRouter biases model tier + provider order the same way the
  `delegate` path already does.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Orchestrate

  test "schema advertises the priority param with immediate|standard|loose" do
    schema = Orchestrate.parameters()
    priority = schema["properties"]["priority"]

    assert priority["type"] == "string"
    assert Enum.sort(priority["enum"]) == ["immediate", "loose", "standard"]
  end

  test "priority is optional (not required)" do
    schema = Orchestrate.parameters()
    assert schema["required"] == ["task"]
    refute "priority" in schema["required"]
  end
end
