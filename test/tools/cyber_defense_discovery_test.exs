defmodule OptimalSystemAgent.Tools.CyberDefenseDiscoveryTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.Handler

  test "defense tool search supplies a callable native schema" do
    assert Registry.module_for("cyber_defense") == OptimalSystemAgent.Tools.Builtins.CyberDefense
    tools = Handler.resolve_tools(%{"query" => "select:cyber_defense"})
    assert Enum.any?(tools, &(&1.name == "cyber_defense"))
    assert {:ok, json} = Registry.execute_direct("cyber_defense", %{"action" => "scenarios"})
    assert length(Jason.decode!(json)["scenarios"]) == 3
  end

  test "natural defense requests discover bundled skills with usable tools" do
    pairs = [
      {"simulate attacks", "attack-simulation"},
      {"detection engineering", "detection-engineering"},
      {"incident response", "incident-response"},
      {"threat hunting", "threat-hunting"}
    ]

    for {query, name} <- pairs do
      assert Enum.any?(Registry.match_skill_triggers(query), fn {found, _} -> found == name end)
      skill = Registry.get_skill(name)
      assert {:ok, body} = Registry.load_skill_body(skill)
      assert byte_size(body) > 200

      for tool <- skill.tools,
          do: assert(Registry.module_for(tool) != nil, "Unknown tool #{tool}")
    end
  end
end
