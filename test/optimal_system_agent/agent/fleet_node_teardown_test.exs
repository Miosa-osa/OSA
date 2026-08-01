defmodule OptimalSystemAgent.Agent.FleetNodeTeardownTest do
  @moduledoc """
  Fleet subagent sessions must not outlive their delegation.

  Every `spawn_fleet_node/2` starts a full-power `Agent.Loop` GenServer for the
  node and nothing ever stopped it, so each delegation leaked a live process
  holding a complete transcript for the life of the daemon.

  Two teardown paths are asserted here as bounds — spawn N nodes, assert the
  live-loop count comes back down:

    * `stop_node/1` — the terminal path `finish/3` takes on success, failure,
      driver crash and idle timeout;
    * `stop_children/1` — the parent-shutdown path, cascaded from
      `Runtime.SessionManager.stop_session/1`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Fleet
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Runtime.SessionManager

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_fleet_td_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:optimal_system_agent, :agent_runs_dir),
        else: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev)

      File.rm_rf(tmp)
    end)

    {:ok, parent: "td-parent-#{System.unique_integer([:positive])}"}
  end

  # Start a real Loop for `node_id` and register it as a child run of `parent`,
  # exactly as do_spawn/2 does.
  defp spawn_node(parent, node_id) do
    RunStore.start_run(%{
      agent_id: node_id,
      parent_session_id: parent,
      role: "general-purpose",
      task: "teardown probe"
    })

    :ok = SessionManager.ensure_loop(node_id, user_id: "fleet", working_dir: File.cwd!())
    node_id
  end

  # Registry entries are cleaned up asynchronously when the owner dies, so a
  # lookup alone can still return a pid for an already-stopped loop. Check the
  # process itself — that is the thing that was leaking.
  defp alive?(session_id) do
    case SessionManager.lookup_loop(session_id) do
      {:ok, pid, _owner} -> Process.alive?(pid)
      _ -> false
    end
  end

  describe "stop_node/1 — the per-delegation terminal path" do
    test "stops a live node loop", %{parent: parent} do
      node = spawn_node(parent, "td-node-#{System.unique_integer([:positive])}")
      assert alive?(node)

      assert :ok = Fleet.stop_node(node)
      refute alive?(node), "a completed fleet node must not leave its Loop running"
    end

    test "is idempotent and safe on an unknown id" do
      assert :ok = Fleet.stop_node("td-never-existed-#{System.unique_integer([:positive])}")
    end

    test "a second stop of an already-stopped node is a no-op", %{parent: parent} do
      node = spawn_node(parent, "td-twice-#{System.unique_integer([:positive])}")
      assert :ok = Fleet.stop_node(node)
      assert :ok = Fleet.stop_node(node)
      refute alive?(node)
    end

    test "stopping one node leaves its siblings running", %{parent: parent} do
      a = spawn_node(parent, "td-sib-a-#{System.unique_integer([:positive])}")
      b = spawn_node(parent, "td-sib-b-#{System.unique_integer([:positive])}")

      Fleet.stop_node(a)

      refute alive?(a)
      assert alive?(b)

      Fleet.stop_node(b)
    end
  end

  describe "stop_children/1 — the parent-shutdown path (the bound)" do
    test "10 delegations leave 0 live loops once the parent stops", %{parent: parent} do
      nodes =
        Enum.map(1..10, fn i ->
          spawn_node(parent, "td-bulk-#{i}-#{System.unique_integer([:positive])}")
        end)

      assert Enum.count(nodes, &alive?/1) == 10

      assert Fleet.stop_children(parent) == 10

      assert Enum.count(nodes, &alive?/1) == 0,
             "every delegated node must die with its parent"
    end

    test "children are marked cancelled, not left :running in the roster", %{parent: parent} do
      node = spawn_node(parent, "td-cancel-#{System.unique_integer([:positive])}")
      Fleet.stop_children(parent)

      assert %{status: status} = RunStore.get(node)
      assert status in [:cancelled, :completed, :failed]

      refute Enum.any?(RunStore.all_running(), &(&1.agent_id == node)),
             "a stopped child must not inflate the running-fleet count"
    end

    test "another parent's nodes are untouched", %{parent: parent} do
      other = "td-other-parent-#{System.unique_integer([:positive])}"
      mine = spawn_node(parent, "td-mine-#{System.unique_integer([:positive])}")
      theirs = spawn_node(other, "td-theirs-#{System.unique_integer([:positive])}")

      Fleet.stop_children(parent)

      refute alive?(mine)
      assert alive?(theirs)

      Fleet.stop_children(other)
    end

    test "a parent with no children is a no-op", %{parent: parent} do
      assert Fleet.stop_children(parent) == 0
    end

    test "SessionManager.stop_session/1 cascades to the children", %{parent: parent} do
      # The parent itself is a live loop with delegated children under it.
      :ok = SessionManager.ensure_loop(parent, user_id: "u", working_dir: File.cwd!())
      child = spawn_node(parent, "td-cascade-#{System.unique_integer([:positive])}")

      assert alive?(parent)
      assert alive?(child)

      SessionManager.stop_session(parent)

      refute alive?(parent)
      refute alive?(child), "stopping a parent session must not strand its fleet nodes"
    end

    test "stop_children never raises on a bad argument" do
      assert Fleet.stop_children(nil) == 0
      assert Fleet.stop_children(:not_a_binary) == 0
    end
  end
end
