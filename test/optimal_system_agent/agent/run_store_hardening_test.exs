defmodule OptimalSystemAgent.Agent.RunStoreHardeningTest do
  @moduledoc """
  Regression test for RunStore bounded retention (finding 18).

  Previously RunStore kept one ETS row per subagent run for the life of the node
  with no prune path, so the table grew without bound over long fan-out sessions.
  complete/1 now evicts oldest terminal rows past a cap, while leaving :running
  rows untouched.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore

  @cap 500

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_runstore_hard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    # Start from a clean, isolated table so other suites' rows don't skew counts.
    RunStore.list()
    :ets.delete_all_objects(RunStore)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)

      File.rm_rf(tmp)
    end)

    :ok
  end

  defp start_and_complete(id, status) do
    RunStore.start_run(%{agent_id: id, parent_session_id: "parent", role: "agent", task: "t"})
    RunStore.complete(id, %{agent_id: id, status: status, duration_ms: 1})
  end

  test "terminal rows stay bounded after many completed runs" do
    for n <- 1..(@cap + 40) do
      start_and_complete("run_#{n}", :completed)
    end

    completed = RunStore.list(limit: 100_000, status: :completed)
    assert length(completed) <= @cap
  end

  test "running rows are never pruned by terminal eviction" do
    # A long-lived running agent.
    RunStore.start_run(%{
      agent_id: "keep_running",
      parent_session_id: "parent",
      role: "agent",
      task: "long"
    })

    # Flood with terminal rows well past the cap.
    for n <- 1..(@cap + 40) do
      start_and_complete("flood_#{n}", :failed)
    end

    assert %{status: :running} = RunStore.get("keep_running")
  end

  describe "reconcile_stale_running/1 (W3/D3)" do
    defp start_running(id, attrs \\ %{}) do
      RunStore.start_run(
        Map.merge(
          %{agent_id: id, parent_session_id: "parent", role: "agent", task: "t"},
          attrs
        )
      )
    end

    test "marks running rows whose process is gone as terminal" do
      start_running("ghost_a")
      start_running("ghost_b")

      # No process is alive for either id.
      reconciled = RunStore.reconcile_stale_running(alive_fun: fn _ -> false end)

      assert Enum.map(reconciled, & &1.agent_id) |> Enum.sort() == ["ghost_a", "ghost_b"]
      assert %{status: :cancelled} = RunStore.get("ghost_a")
      assert %{status: :cancelled} = RunStore.get("ghost_b")
    end

    test "leaves running rows whose process is still alive untouched" do
      start_running("alive_one")
      start_running("dead_one")

      reconciled =
        RunStore.reconcile_stale_running(alive_fun: fn id -> id == "alive_one" end)

      assert Enum.map(reconciled, & &1.agent_id) == ["dead_one"]
      assert %{status: :running} = RunStore.get("alive_one")
      assert %{status: :cancelled} = RunStore.get("dead_one")
    end

    test "does not touch already-terminal rows (counts don't regress)" do
      start_and_complete("done_one", :completed)

      reconciled = RunStore.reconcile_stale_running(alive_fun: fn _ -> false end)

      assert reconciled == []
      assert %{status: :completed} = RunStore.get("done_one")
    end

    test "honours a custom terminal status and records a reason on the row" do
      start_running("orphan_fail")

      [row] =
        RunStore.reconcile_stale_running(alive_fun: fn _ -> false end, status: :failed)

      assert row.status == :failed
      assert %{status: :failed} = RunStore.get("orphan_fail")
      assert row.result.status == :failed
      assert is_binary(row.result.summary)
    end

    test "all_running/0 returns every running row, unbounded" do
      for n <- 1..30, do: start_running("run_all_#{n}")

      running = RunStore.all_running()
      assert length(running) == 30
      assert Enum.all?(running, fn r -> r.status == :running end)
    end

    test "start_run/1 accepts an optional posture and preserves it" do
      start_running("auto_run", %{posture: :autonomous})
      assert %{posture: :autonomous} = RunStore.get("auto_run")
    end
  end
end
