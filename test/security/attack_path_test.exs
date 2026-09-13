defmodule OptimalSystemAgent.Security.AttackPathTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.AttackPath

  defp triangle do
    AttackPath.new()
    |> AttackPath.add_edge("user:alice", "group:admins", :MemberOf, %{cost: 1})
    |> AttackPath.add_edge("group:admins", "computer:dc", :AdminTo, %{cost: 2})
  end

  test "shortest path is the cheap route" do
    g =
      triangle()
      |> AttackPath.add_edge("user:alice", "computer:dc", :GenericAll, %{cost: 10})

    assert {:ok, path} = AttackPath.shortest_path(g, "user:alice", "computer:dc")
    assert path.nodes == ["user:alice", "group:admins", "computer:dc"]
    assert path.cost == 3.0
    assert length(path.edges) == 2
  end

  test "unreachable and unknown nodes" do
    g = triangle()
    assert :unreachable = AttackPath.shortest_path(g, "computer:dc", "user:alice")
    assert {:error, _} = AttackPath.shortest_path(g, "nope", "computer:dc")
  end

  test "paths_from lists reachable targets under max_cost" do
    paths = AttackPath.paths_from(triangle(), "user:alice", max_cost: 2)
    # cost 1 to group, cost 3 to dc - only group survives the cap
    assert Enum.any?(paths, fn p -> List.last(p.nodes) == "group:admins" end)
    refute Enum.any?(paths, fn p -> List.last(p.nodes) == "computer:dc" end)
  end

  test "bloodhound ingest builds the graph" do
    json = """
    {"nodes":[{"id":"U1","kind":"User","label":"alice"},{"id":"C1","kind":"Computer","label":"dc"}],
     "edges":[{"source":"U1","target":"C1","kind":"AdminTo","cost":1}]}
    """

    assert {:ok, g} = AttackPath.ingest_bloodhound(AttackPath.new(), json)
    assert {:ok, path} = AttackPath.shortest_path(g, "U1", "C1")
    assert path.cost == 1.0
    assert hd(path.edges).type == :AdminTo
  end
end
