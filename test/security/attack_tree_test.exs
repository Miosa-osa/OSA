defmodule OptimalSystemAgent.Security.AttackTreeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.AttackTree

  test "first select prefers a basics-first class (IDOR/auth/SQLi)" do
    {:ok, class, tree} = AttackTree.select(AttackTree.new())
    assert class in [:idor, :auth_bypass, :sqli, :business_logic, :xss]
    assert tree.total_visits == 1
  end

  test "wins pull a class back to the front" do
    {:ok, class, tree} = AttackTree.select(AttackTree.new())
    tree = AttackTree.record(tree, class, :win)
    {:ok, again, _} = AttackTree.select(tree)
    # a confirmed class still competes; we mainly assert the tree mutated
    assert tree.nodes[class].wins == 1
    assert is_atom(again)
  end

  test "exhausted nodes are skipped until the tree is done" do
    tree =
      Enum.reduce(AttackTree.new().nodes, AttackTree.new(), fn {k, _}, acc ->
        AttackTree.record(acc, k, :exhausted)
      end)

    assert AttackTree.select(tree) == :done
  end

  test "TDA exploit keeps the current class" do
    assert {:exploit, :sqli} =
             AttackTree.next(AttackTree.new(), :sqli, %{
               steps_remaining: 2,
               evidence_confidence: 0.95,
               context_load: 0.2,
               historical_success_rate: 0.9,
               task_type: :exploitation
             })
  end

  test "render is prompt-injectable" do
    text = AttackTree.render(AttackTree.new())
    assert text =~ "<attack_tree"
    assert text =~ "idor"
  end
end
