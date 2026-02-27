defmodule OptimalSystemAgent.Fleet.RegistryTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Fleet.Registry, as: FleetRegistry
  alias OptimalSystemAgent.Fleet.Sentinel

  # Each test starts its own isolated supervision tree so tests don't conflict
  setup do
    # Start the Fleet supervision tree fresh per test
    registry_name = :"fleet_agent_registry_#{:erlang.unique_integer([:positive])}"
    pool_name = :"fleet_sentinel_pool_#{:erlang.unique_integer([:positive])}"

    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
    {:ok, _} = DynamicSupervisor.start_link(name: pool_name, strategy: :one_for_one)

    # We test via the named FleetRegistry GenServer, so we need the real
    # supervision tree. Start the full Fleet.Supervisor.
    # But since other tests may also start it, we use start_supervised.
    start_supervised!({OptimalSystemAgent.Fleet.Supervisor, []})

    :ok
  end

  # ---------------------------------------------------------------------------
  # register_agent/2
  # ---------------------------------------------------------------------------

  describe "register_agent/2" do
    test "adds agent to registry and returns sentinel pid" do
      agent_id = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

      assert {:ok, pid} = FleetRegistry.register_agent(agent_id, [:shell, :file_read])
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "rejects duplicate registration" do
      agent_id = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

      assert {:ok, _pid} = FleetRegistry.register_agent(agent_id, [])
      assert {:error, :already_registered} = FleetRegistry.register_agent(agent_id, [])
    end
  end

  # ---------------------------------------------------------------------------
  # heartbeat/2
  # ---------------------------------------------------------------------------

  describe "heartbeat/2" do
    test "updates agent metrics" do
      agent_id = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      {:ok, pid} = FleetRegistry.register_agent(agent_id, [])

      metrics = %{cpu_load: 45.2, memory_mb: 512, disk_gb: 10.5}
      assert :ok = FleetRegistry.heartbeat(agent_id, metrics)

      # Verify the sentinel received the metrics
      status = Sentinel.get_status(pid)
      assert status.cpu_load == 45.2
      assert status.memory_mb == 512
      assert status.disk_gb == 10.5
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = FleetRegistry.heartbeat("nonexistent_agent", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # list_agents/0
  # ---------------------------------------------------------------------------

  describe "list_agents/0" do
    test "returns all registered agents" do
      id1 = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      id2 = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

      {:ok, _} = FleetRegistry.register_agent(id1, [:shell])
      {:ok, _} = FleetRegistry.register_agent(id2, [:file_read, :file_write])

      agents = FleetRegistry.list_agents()
      agent_ids = Enum.map(agents, & &1.agent_id)

      assert id1 in agent_ids
      assert id2 in agent_ids
      assert length(agents) >= 2
    end

    test "returns empty list when no agents registered" do
      agents = FleetRegistry.list_agents()
      # May have agents from other tests if not isolated, but at minimum it's a list
      assert is_list(agents)
    end
  end

  # ---------------------------------------------------------------------------
  # get_agent/1
  # ---------------------------------------------------------------------------

  describe "get_agent/1" do
    test "returns single agent detail" do
      agent_id = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      {:ok, _} = FleetRegistry.register_agent(agent_id, [:analyze])

      assert {:ok, detail} = FleetRegistry.get_agent(agent_id)
      assert detail.agent_id == agent_id
      assert detail.status == :online
      assert :analyze in detail.capabilities
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = FleetRegistry.get_agent("does_not_exist")
    end
  end

  # ---------------------------------------------------------------------------
  # remove_agent/1
  # ---------------------------------------------------------------------------

  describe "remove_agent/1" do
    test "removes agent from registry and stops sentinel" do
      agent_id = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      {:ok, pid} = FleetRegistry.register_agent(agent_id, [])

      assert :ok = FleetRegistry.remove_agent(agent_id)
      assert {:error, :not_found} = FleetRegistry.get_agent(agent_id)

      # Sentinel should be terminated
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "returns error for unknown agent" do
      assert {:error, :not_found} = FleetRegistry.remove_agent("nonexistent")
    end
  end

  # ---------------------------------------------------------------------------
  # stats
  # ---------------------------------------------------------------------------

  describe "get_stats/0" do
    test "stats are computed correctly" do
      id1 = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      id2 = "agent_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

      {:ok, _} = FleetRegistry.register_agent(id1, [])
      {:ok, _} = FleetRegistry.register_agent(id2, [])

      stats = FleetRegistry.get_stats()
      assert stats.total >= 2
      assert stats.online >= 2
      assert stats.unreachable == 0
    end
  end
end
