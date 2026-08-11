defmodule OptimalSystemAgent.Decisions.TeamIsolationTest do
  @moduledoc """
  Team isolation across the decision graph.

  `Decisions.Graph`'s moduledoc promises "Nodes from different teams are never
  mixed", and `descendants/2` documents a `:team_id` option that "Respects team
  isolation". Neither was true:

    * `do_traverse/4` took `team_id` and named it `_team_id` — the walk crossed
      into other teams' subgraphs unchecked, and isolation was only a post-hoc
      filter on the collected node list.
    * `Decisions.Cascade` followed outgoing edges with no team check at all,
      REWROTE other teams' confidence values, and broadcast each updated node —
      whole map, `title`, `description`, `metadata` — onto the ORIGIN team's
      PubSub topic. That is a cross-team content leak.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Decisions.Cascade
  alias OptimalSystemAgent.Decisions.Graph

  # `Graph.node_to_map/1` resolves stored strings with `String.to_existing_atom/1`,
  # so the atoms must already exist in this VM.
  @atoms [:decision, :active, :leads_to]

  setup do
    _ = @atoms
    Graph.init_tables()
    suffix = System.unique_integer([:positive])
    {:ok, team_a: "team-A-#{suffix}", team_b: "team-B-#{suffix}"}
  end

  defp node!(team_id, title) do
    {:ok, node} =
      Graph.add_node(%{title: title, type: "decision", status: "active", team_id: team_id})

    node
  end

  defp edge!(source, target) do
    {:ok, edge} = Graph.add_edge(source.id, target.id, "leads_to", weight: 1.0)
    edge
  end

  describe "Graph.descendants/2" do
    test "stops at the team boundary instead of walking through it", ctx do
      # a1 -> b1 -> a2 : a2 is only reachable THROUGH team B.
      a1 = node!(ctx.team_a, "a1")
      b1 = node!(ctx.team_b, "b1")
      a2 = node!(ctx.team_a, "a2")

      edge!(a1, b1)
      edge!(b1, a2)

      {:ok, nodes} = Graph.descendants(a1.id, team_id: ctx.team_a)
      ids = Enum.map(nodes, & &1.id)

      assert a1.id in ids
      refute b1.id in ids, "traversal leaked into team B"

      refute a2.id in ids,
             "a2 is only reachable through team B — collecting it means the walk crossed the boundary"
    end

    test "team_id: nil still walks the whole graph", ctx do
      a1 = node!(ctx.team_a, "a1")
      b1 = node!(ctx.team_b, "b1")
      edge!(a1, b1)

      {:ok, nodes} = Graph.descendants(a1.id, team_id: nil)
      ids = Enum.map(nodes, & &1.id)

      assert a1.id in ids
      assert b1.id in ids
    end
  end

  describe "Cascade.propagate/2" do
    test "does not rewrite another team's confidence", ctx do
      a1 = node!(ctx.team_a, "a1")
      b1 = node!(ctx.team_b, "b1")
      edge!(a1, b1)

      {:ok, _count} = Cascade.propagate(a1.id, 0.10)

      {:ok, b1_after} = Graph.get_node(b1.id)
      assert b1_after.confidence == 1.0, "team B's node was rewritten by a team A cascade"
    end

    test "never broadcasts another team's node onto the origin team's topic", ctx do
      a1 = node!(ctx.team_a, "a1")
      b1 = node!(ctx.team_b, "b1")
      edge!(a1, b1)

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:dg:team:#{ctx.team_a}")

      {:ok, _count} = Cascade.propagate(a1.id, 0.10)

      refute_receive {:confidence_updated, %{team_id: team_b}} when team_b == ctx.team_b,
                     500,
                     "team B's node map leaked onto team A's topic"
    end

    test "still propagates within the same team", ctx do
      a1 = node!(ctx.team_a, "a1")
      a2 = node!(ctx.team_a, "a2")
      edge!(a1, a2)

      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:dg:team:#{ctx.team_a}")

      {:ok, count} = Cascade.propagate(a1.id, 0.10)

      assert count == 1
      assert_receive {:confidence_updated, updated}, 500
      assert updated.id == a2.id

      {:ok, a2_after} = Graph.get_node(a2.id)
      assert_in_delta a2_after.confidence, 0.10, 0.0001
    end
  end
end
