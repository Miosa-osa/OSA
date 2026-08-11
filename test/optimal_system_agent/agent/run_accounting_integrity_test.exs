defmodule OptimalSystemAgent.Agent.RunAccountingIntegrityTest do
  @moduledoc """
  Two related integrity properties of run status + tree spend.

  1. `RunStore.complete/2` must not demote an already-settled run, and must not
     shrink its counters. A run cancelled by `handle_ownership_loss/1` or
     `reconcile_stale_running/1` used to be promoted straight back to
     `:completed` by the still-draining loop's own later `complete/2`.

  2. The tree spend rollup must not be derivable from an evictable cache.
     `prune_terminal/0` drops terminal rows past 500 machine-globally while a
     fleet may run up to 1000 nodes, so a rollup built on `RunStore.list/1` lost
     the pruned nodes' cost, `budget_exhausted?/1` flipped back to false, and
     spawning resumed past an explicit `max_budget_usd`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.SessionPersistence

  @prune_cap 500

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_run_acct_#{System.unique_integer([:positive])}")
    runs = Path.join(tmp, "runs")
    home = Path.join(tmp, "home")
    File.mkdir_p!(runs)
    File.mkdir_p!(home)

    prev_runs = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    prev_home = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, runs)
    Application.put_env(:optimal_system_agent, :config_dir, home)

    # Isolated tables so other suites' rows don't skew the rollup.
    RunStore.list()
    :ets.delete_all_objects(RunStore)

    on_exit(fn ->
      restore_env(:agent_runs_dir, prev_runs)
      restore_env(:config_dir, prev_home)
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  describe "complete/2 monotonicity" do
    test "a cancelled run is NOT promoted back to :completed by a late complete/2" do
      id = "run-cancel-#{System.unique_integer([:positive])}"
      RunStore.start_run(%{agent_id: id, parent_session_id: "p", role: "gp", task: "t"})

      # Ownership loss / stale reconciliation settles the run as cancelled...
      RunStore.complete(id, %{status: :cancelled, summary: "lease lost"})
      # ...and the loop that is still draining reports its own success later.
      RunStore.complete(id, %{status: :completed, summary: "done"})

      assert RunStore.get(id).status == :cancelled
    end

    test "a failed run is NOT flipped green by a duplicate complete/2" do
      id = "run-fail-#{System.unique_integer([:positive])}"
      RunStore.start_run(%{agent_id: id, parent_session_id: "p", role: "gp", task: "t"})

      RunStore.complete(id, %{status: :failed, summary: "boom"})
      RunStore.complete(id, %{status: :completed, summary: "done"})

      assert RunStore.get(id).status == :failed
    end

    test "counters never decrease across complete/2" do
      id = "run-counters-#{System.unique_integer([:positive])}"
      RunStore.start_run(%{agent_id: id, parent_session_id: "p", role: "gp", task: "t"})
      RunStore.progress(id, "did a thing", 7)

      # A completion carrying a stale/zeroed count must not erase real usage.
      RunStore.complete(id, %{status: :completed, tool_count: 0, tokens_used: 0})

      run = RunStore.get(id)
      assert run.tool_count == 7
      assert run.status == :completed
    end

    test "a first, clean completion still records status and result" do
      id = "run-clean-#{System.unique_integer([:positive])}"
      RunStore.start_run(%{agent_id: id, parent_session_id: "p", role: "gp", task: "t"})
      RunStore.complete(id, %{status: :completed, tool_count: 3, summary: "ok"})

      run = RunStore.get(id)
      assert run.status == :completed
      assert run.tool_count == 3
      assert run.completed_at
      assert run.result[:summary] == "ok"
    end
  end

  describe "tree spend survives run-row pruning" do
    @tag timeout: 120_000
    test "budget_exhausted? still sees nodes that prune_terminal evicted" do
      root = "root-#{System.unique_integer([:positive])}"
      n = @prune_cap + 40

      for i <- 1..n do
        child = "#{root}-c#{i}"
        RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "gp", task: "t"})
        SessionPersistence.save_spend(child, %{cost_usd: 0.01})
        RunStore.complete(child, %{status: :completed})
      end

      # The run TABLE has been pruned back to the cap...
      terminal_rows =
        RunStore.list()
        |> Enum.filter(&(&1.parent_session_id == root))
        |> length()

      assert terminal_rows <= @prune_cap

      # ...but the spend ledger still accounts for every node that ran.
      state = %{session_id: root, session_cost_usd: 0.0, max_budget_usd: 5.2}

      assert_in_delta Accounting.tree_spend_usd(state), n * 0.01, 0.001
      assert Accounting.budget_exhausted?(state)
    end

    test "a node reachable from two parents is counted once" do
      root = "diamond-#{System.unique_integer([:positive])}"
      b = "#{root}-b"
      c = "#{root}-c"
      d = "#{root}-d"

      RunStore.start_run(%{agent_id: b, parent_session_id: root, role: "gp", task: "t"})
      RunStore.start_run(%{agent_id: c, parent_session_id: root, role: "gp", task: "t"})
      # `d` is registered under BOTH branches (a re-parent mid-run).
      RunStore.start_run(%{agent_id: d, parent_session_id: b, role: "gp", task: "t"})
      RunStore.start_run(%{agent_id: d, parent_session_id: c, role: "gp", task: "t"})

      for id <- [b, c, d], do: SessionPersistence.save_spend(id, %{cost_usd: 1.0})

      state = %{session_id: root, session_cost_usd: 0.0}
      assert_in_delta Accounting.tree_spend_usd(state), 3.0, 0.001
    end
  end
end
