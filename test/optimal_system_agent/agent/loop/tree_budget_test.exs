defmodule OptimalSystemAgent.Agent.Loop.TreeBudgetTest do
  @moduledoc """
  W2 — the fleet/tree budget rollup.

  A `max_budget_usd` cap on a parent must bound the WHOLE run tree, not each
  fleet node independently. N children each under their own (absent) cap could
  otherwise blow the intended total. `Accounting.tree_spend_usd/1` rolls up the
  parent's own live spend PLUS every descendant fleet node's persisted spend
  (read-only from `RunStore` + `SessionPersistence`);
  `Accounting.budget_exhausted?/1` / `tree_budget_remaining/1` are the helpers
  fan_out (and the loop budget guard) check before spawning more nodes.

  Also covers item #3: a `max_budget_usd` restored from a crash checkpoint still
  bounds a RESUMED fleet (the restored cap + rolled-up tree spend trips the
  exhaustion check).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.SessionPersistence

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_treebudget_#{System.unique_integer([:positive])}")
    crash = Path.join(tmp, "checkpoints")
    home = Path.join(tmp, "home")
    File.mkdir_p!(crash)
    File.mkdir_p!(home)

    prev_crash = Application.get_env(:optimal_system_agent, :checkpoint_dir)
    prev_home = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :checkpoint_dir, crash)
    Application.put_env(:optimal_system_agent, :config_dir, home)

    on_exit(fn ->
      restore_env(:checkpoint_dir, prev_crash)
      restore_env(:config_dir, prev_home)
      File.rm_rf(tmp)
    end)

    {:ok, root: "root_#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  # Register a fleet node in the run tree and give it a persisted spend sidecar.
  defp child(parent, cost) do
    id = "child_#{System.unique_integer([:positive])}"
    RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "fleet-node", task: "t"})
    SessionPersistence.save_spend(id, %{cost_usd: cost})
    id
  end

  describe "tree_spend_usd/1 rolls up own + descendant spend" do
    test "no descendants → just the parent's own spend", %{root: root} do
      state = %{session_id: root, session_cost_usd: 5.0}
      assert Accounting.tree_spend_usd(state) == 5.0
    end

    test "sums parent own spend + every direct child's persisted spend", %{root: root} do
      _ = child(root, 20.0)
      _ = child(root, 20.0)
      _ = child(root, 20.0)

      state = %{session_id: root, session_cost_usd: 5.0}
      # 5 (own) + 3*20 (children) = 65
      assert Accounting.tree_spend_usd(state) == 65.0
    end

    test "sums grandchildren too (whole subtree, not just direct children)", %{root: root} do
      c1 = child(root, 10.0)
      _gc = child(c1, 7.5)

      state = %{session_id: root, session_cost_usd: 1.0}
      assert Accounting.tree_spend_usd(state) == 18.5
    end

    test "ignores runs outside this root's subtree", %{root: root} do
      other = "other_#{System.unique_integer([:positive])}"
      _ = child(other, 999.0)
      _ = child(root, 4.0)

      state = %{session_id: root, session_cost_usd: 1.0}
      assert Accounting.tree_spend_usd(state) == 5.0
    end
  end

  describe "budget_exhausted?/1 + tree_budget_remaining/1" do
    test "nil / non-positive cap is never exhausted (uncapped)", %{root: root} do
      _ = child(root, 1000.0)
      assert Accounting.budget_exhausted?(%{session_id: root, session_cost_usd: 0.0}) == false

      assert Accounting.budget_exhausted?(%{
               session_id: root,
               session_cost_usd: 0.0,
               max_budget_usd: nil
             }) == false

      assert Accounting.tree_budget_remaining(%{session_id: root, session_cost_usd: 0.0}) ==
               :infinity
    end

    test "children under their own (absent) caps can blow the tree cap", %{root: root} do
      # Three $20 children with NO individual cap → $60 tree spend defeats a $50
      # tree cap even though no single node exceeded anything.
      _ = child(root, 20.0)
      _ = child(root, 20.0)
      _ = child(root, 20.0)

      state = %{session_id: root, session_cost_usd: 0.0, max_budget_usd: 50.0}
      assert Accounting.budget_exhausted?(state) == true
      assert Accounting.tree_budget_remaining(state) == 0.0
    end

    test "under the cap → not exhausted, positive remaining", %{root: root} do
      _ = child(root, 10.0)
      state = %{session_id: root, session_cost_usd: 5.0, max_budget_usd: 50.0}

      assert Accounting.budget_exhausted?(state) == false
      assert Accounting.tree_budget_remaining(state) == 35.0
    end
  end

  describe "item #3 — a restored max_budget_usd bounds a RESUMED fleet" do
    test "cap restored from a crash checkpoint + rolled-up tree spend trips exhaustion",
         %{root: root} do
      # A run started with an explicit $50 cap that spent $30 crashes. The cap +
      # the parent's own spend are persisted in the crash checkpoint.
      Checkpoint.checkpoint_state(%{
        session_id: root,
        messages: [],
        iteration: 3,
        plan_mode: false,
        turn_count: 1,
        session_cost_usd: 30.0,
        max_budget_usd: 50.0,
        started_at: ~U[2026-07-20 00:00:00Z]
      })

      # On resume the fleet's descendant nodes are still in the run tree with
      # their persisted spend ($15 + $10).
      _ = child(root, 15.0)
      _ = child(root, 10.0)

      restored = Checkpoint.restore_checkpoint(root)
      assert restored.max_budget_usd == 50.0
      assert restored.session_cost_usd == 30.0

      # Mirror loop.init: resumed state carries the restored cap + restored own
      # spend; the tree rollup then adds the live descendants.
      resumed = %{
        session_id: root,
        session_cost_usd: restored.session_cost_usd,
        max_budget_usd: restored.max_budget_usd
      }

      # 30 (own, restored) + 15 + 10 (descendants) = 55 > 50 cap.
      assert Accounting.tree_spend_usd(resumed) == 55.0
      assert Accounting.budget_exhausted?(resumed) == true
      assert Accounting.tree_budget_remaining(resumed) == 0.0
    end
  end

  # The rollup existed but was wired ONLY to the budget guard. Every figure a
  # human or a benchmark reads — `session_cost_usd`, the `:cost_update` event,
  # the spend sidecar — was the parent's own spend alone, so a run whose arms
  # delegate under-reported `$/task` by however much the children cost.
  #
  # Both figures are now published side by side, explicitly named. Neither one
  # silently changes meaning, because both meanings are load-bearing: the
  # node-local figure is what every rollup sums, and a tree total in that slot
  # would make every ancestor double-count its grandchildren.
  describe "the reported figures carry BOTH the node and the tree bill" do
    test "snapshot/1 exposes node spend, tree spend, and whether the tree bill is complete",
         %{root: root} do
      _ = child(root, 20.0)
      _ = child(root, 12.5)

      snap =
        Accounting.snapshot(%{
          session_id: root,
          session_cost_usd: 5.0,
          session_input_tokens: 10,
          session_output_tokens: 2
        })

      # Node-local — unchanged meaning, and what `Fleet.default_budget_exhausted?/1`
      # feeds back into `budget_exhausted?/1`.
      assert snap.cost_usd == 5.0
      # Whole tree — what "$ per task" means once an arm delegates.
      assert snap.tree_cost_usd == 37.5
      assert snap.tree_cost_complete == true
    end

    test "a childless session reports the same number twice, not a surprise", %{root: root} do
      snap = Accounting.snapshot(%{session_id: root, session_cost_usd: 3.25})
      assert snap.cost_usd == 3.25
      assert snap.tree_cost_usd == 3.25
    end

    test "the spend sidecar keeps cost_usd NODE-LOCAL and adds tree_cost_usd beside it",
         %{root: root} do
      # This is the invariant the whole rollup rests on: `tree_spend/1` sums
      # `cost_usd` across every descendant sidecar. If a parent wrote its tree
      # total there, a grandparent would count the grandchildren twice.
      c1 = child(root, 10.0)
      _gc = child(c1, 4.0)

      SessionPersistence.save_from_state(root, %{
        session_id: root,
        session_cost_usd: 2.0,
        messages: [],
        model: "claude-3-5-sonnet"
      })

      loaded = SessionPersistence.load_spend(root)
      assert loaded.cost_usd == 2.0
      assert loaded.tree_cost_usd == 16.0
    end

    test "a sidecar written before tree_cost_usd existed falls back to the node figure" do
      id = "legacy_#{System.unique_integer([:positive])}"
      SessionPersistence.save_spend(id, %{cost_usd: 1.75})

      loaded = SessionPersistence.load_spend(id)
      # Correct for a childless session, and a LOWER BOUND otherwise — never an
      # over-statement.
      assert loaded.tree_cost_usd == 1.75
    end
  end
end
