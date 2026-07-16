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
end
