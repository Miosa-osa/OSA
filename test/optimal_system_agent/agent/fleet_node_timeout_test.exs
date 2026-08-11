defmodule OptimalSystemAgent.Agent.FleetNodeTimeoutTest do
  @moduledoc """
  A fan-out timeout must kill the WORKER, not the poller.

  `Task.async_stream(on_timeout: :kill_task)` was set to the same
  `node_timeout_ms()` as the in-task completion wait, and the outer clock starts
  first — so the outer deadline always won. It kills the polling task, which
  leaves the node's own Loop running, uncancelled, still writing to its
  worktree, while the drain records `fail_result("", :node_timeout)`: an EMPTY
  node_id and a nil `worktree_ref`.

  A nil ref is data loss, not just a cosmetic gap: `Fleet.Finalizer` merges a
  node's work with `git checkout <worktree_ref> -- <files>`, so everything that
  node wrote is silently never merged and its branch is orphaned.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.RunStore

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_fleet_to_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_runs = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    prev_node_timeout = Application.get_env(:optimal_system_agent, :node_timeout_ms)
    prev_ack = Application.get_env(:optimal_system_agent, :fleet_cancel_ack_ms)
    prev_poll = Application.get_env(:optimal_system_agent, :fleet_await_poll_ms)
    prev_effort = Application.get_env(:optimal_system_agent, :effort_level)

    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)
    Effort.set(:ultra)

    on_exit(fn ->
      restore(:agent_runs_dir, prev_runs)
      restore(:node_timeout_ms, prev_node_timeout)
      restore(:fleet_cancel_ack_ms, prev_ack)
      restore(:fleet_await_poll_ms, prev_poll)
      restore(:effort_level, prev_effort)
      File.rm_rf(tmp)
    end)

    {:ok, parent: "parent_#{System.unique_integer([:positive])}"}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  describe "timeout ladder" do
    test "the outer async_stream backstop is strictly longer than the in-task ceiling" do
      Application.put_env(:optimal_system_agent, :node_timeout_ms, 5_000)

      assert Fleet.fan_out_task_timeout_ms() > Fleet.node_timeout_ms(),
             "the outer deadline can win the race and kill the poller before the " <>
               "in-task ceiling can identify and cancel the node"
    end
  end

  describe "a node that blows its ceiling" do
    test "is reported with its REAL node id, not an empty one", %{parent: parent} do
      Application.put_env(:optimal_system_agent, :node_timeout_ms, 400)
      Application.put_env(:optimal_system_agent, :fleet_cancel_ack_ms, 300)
      Application.put_env(:optimal_system_agent, :fleet_await_poll_ms, 50)

      # A node that registers a real run row and then never terminates.
      spawn_fun = fn p, opts ->
        node_id = "stuck_" <> to_string(Keyword.get(opts, :task, "x"))

        RunStore.start_run(%{
          agent_id: node_id,
          parent_session_id: p,
          role: "fleet-node",
          task: "stuck"
        })

        {:ok, node_id}
      end

      assert {:ok, %{results: [result]}} =
               Fleet.fan_out(parent, ["alpha"], spawn_fun: spawn_fun)

      assert result.gate == :fail

      assert result.node_id == "stuck_alpha",
             "the timed-out node was recorded under an empty id — its identity, and with it " <>
               "the ability to find its worktree, was lost with the killed poller"
    end

    test "keeps the worktree ref so the finalizer can still see its work",
         %{parent: parent} do
      Application.put_env(:optimal_system_agent, :node_timeout_ms, 400)
      Application.put_env(:optimal_system_agent, :fleet_cancel_ack_ms, 300)
      Application.put_env(:optimal_system_agent, :fleet_await_poll_ms, 50)

      spawn_fun = fn p, _opts ->
        node_id = "stuck_wt_#{System.unique_integer([:positive])}"

        RunStore.start_run(%{
          agent_id: node_id,
          parent_session_id: p,
          role: "fleet-node",
          task: "stuck"
        })

        {:ok, node_id}
      end

      worktree_fun = fn _p, _merged ->
        {:ok, %{path: Path.join(System.tmp_dir!(), "fake_wt"), branch: "osa-wt-stuck"}}
      end

      assert {:ok, %{results: [result]}} =
               Fleet.fan_out(parent, ["beta"],
                 spawn_fun: spawn_fun,
                 worktree_fun: worktree_fun,
                 isolation: :worktree
               )

      assert result.gate == :fail

      assert result.worktree_ref == "osa-wt-stuck",
             "the timed-out node lost its worktree ref — `git checkout <ref> -- <files>` can " <>
               "never merge what it wrote"
    end

    test "a node that DOES reach a terminal state is not affected", %{parent: parent} do
      Application.put_env(:optimal_system_agent, :node_timeout_ms, 5_000)
      Application.put_env(:optimal_system_agent, :fleet_await_poll_ms, 20)

      spawn_fun = fn p, _opts ->
        node_id = "quick_#{System.unique_integer([:positive])}"

        RunStore.start_run(%{
          agent_id: node_id,
          parent_session_id: p,
          role: "fleet-node",
          task: "quick"
        })

        RunStore.complete(node_id, %{status: :completed})
        {:ok, node_id}
      end

      assert {:ok, %{results: [result]}} =
               Fleet.fan_out(parent, ["gamma"], spawn_fun: spawn_fun)

      assert result.gate == :pass
      assert result.node_id =~ "quick_"
    end
  end
end
