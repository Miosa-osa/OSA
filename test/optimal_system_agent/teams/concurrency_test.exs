defmodule OptimalSystemAgent.Teams.ConcurrencyTest do
  @moduledoc """
  Lost-update and stranded-waiter regressions in the team subsystem.

    * `Manager.register_child/2` was a get -> update -> write over shared ETS
      run in the CALLER's process, so two sub-teams created concurrently under
      the same parent both read the same `child_ids` and one was dropped.
      `dissolve_team/1` walks `child_ids`, so a dropped id leaks that team's
      agents, ETS rows and nervous-system processes permanently.
    * `AgentState.record_cost/4` (and its siblings) were get -> struct-update ->
      `:ets.insert/2` with no atomicity, so concurrent cost reports silently
      discarded each other.
    * `Rendezvous.create/3` `Map.put`ed a fresh barrier over a live one,
      throwing away the `from` refs of everyone blocked in a 60s
      `GenServer.call` — those callers could never be replied to.
    * `ConflictDetector` never monitored a lock holder, so an agent that died
      mid-edit held its file lock for the life of the team.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Teams.AgentState
  alias OptimalSystemAgent.Teams.Manager
  alias OptimalSystemAgent.Teams.NervousSystem

  defp team_id, do: "t#{System.unique_integer([:positive])}"

  describe "AgentState atomic mutation" do
    test "concurrent record_cost/4 calls do not lose writes" do
      tid = team_id()
      agent_id = "agent-1"
      AgentState.put(tid, AgentState.new(agent_id, "a", "worker", "m"))

      writers = 40

      1..writers
      |> Enum.map(fn _ ->
        Task.async(fn -> AgentState.record_cost(tid, agent_id, 10, 0.5) end)
      end)
      |> Task.await_many(10_000)

      state = AgentState.get(tid, agent_id)
      assert state.token_usage == writers * 10
      assert_in_delta state.cost_usd, writers * 0.5, 0.0001
    end

    test "concurrent increment_escalation/2 calls do not lose writes" do
      tid = team_id()
      agent_id = "agent-2"
      AgentState.put(tid, AgentState.new(agent_id, "a", "worker", "m"))

      1..30
      |> Enum.map(fn _ ->
        Task.async(fn -> AgentState.increment_escalation(tid, agent_id) end)
      end)
      |> Task.await_many(10_000)

      assert AgentState.get(tid, agent_id).escalation_count == 30
    end

    test "a missing agent is still reported as not_found" do
      assert {:error, :not_found} = AgentState.record_cost(team_id(), "nope", 1, 1.0)
    end
  end

  describe "Manager.create_team/1" do
    @tag timeout: 15_000
    test "returns instead of deadlocking against its own supervisor" do
      # `Manager.init/1` used to call `NervousSystem.start_all/1`, which issues
      # `DynamicSupervisor.start_child/2` against `Teams.Supervisor` — the very
      # supervisor blocked in `proc_lib.sync_start/2` waiting for that init to
      # return. Neither side has a timeout, so `create_team/1` never returned
      # and the `team_create` tool hung forever.
      tid = team_id()

      assert {:ok, meta} = Manager.create_team(%{name: "deadlock-check", team_id: tid})
      assert meta.team_id == tid

      # And the nervous system really is up by the time it returns.
      assert [{_pid, _}] =
               Registry.lookup(
                 OptimalSystemAgent.Registry,
                 {NervousSystem.ConflictDetector, tid}
               )

      Manager.dissolve_team(tid)
    end
  end

  describe "Manager.create_sub_team/3" do
    test "concurrent sub-team creation records every child" do
      parent = team_id()
      {:ok, _meta} = Manager.create_team(%{name: "parent", team_id: parent})

      children =
        1..6
        |> Enum.map(fn i ->
          Task.async(fn -> Manager.create_sub_team(parent, "child-#{i}") end)
        end)
        |> Task.await_many(20_000)
        |> Enum.map(fn {:ok, meta} -> meta.team_id end)

      recorded = Manager.get_team(parent).child_ids

      for child <- children do
        assert child in recorded, "child #{child} was dropped by a concurrent registration"
      end

      Manager.dissolve_team(parent)
    end
  end

  describe "NervousSystem.Rendezvous" do
    test "re-creating a barrier does not strand agents already blocked on it" do
      tid = team_id()
      {:ok, _meta} = Manager.create_team(%{name: "rv", team_id: tid})

      assert :ok = NervousSystem.Rendezvous.create(tid, "gate", 2)

      test_pid = self()

      waiter =
        spawn(fn ->
          result = NervousSystem.Rendezvous.arrive(tid, "gate", "agent-1", 3_000)
          send(test_pid, {:arrived, result})
        end)

      Process.sleep(100)

      # A second create must not clobber the barrier the waiter is parked on.
      assert {:error, :already_exists} = NervousSystem.Rendezvous.create(tid, "gate", 2)

      # The original barrier is intact, so the second arrival still opens it.
      assert :go = NervousSystem.Rendezvous.arrive(tid, "gate", "agent-2", 3_000)
      assert_receive {:arrived, :go}, 3_000

      refute Process.alive?(waiter)
      Manager.dissolve_team(tid)
    end
  end

  describe "NervousSystem.ConflictDetector" do
    test "a dead lock holder's file lock is released" do
      tid = team_id()
      {:ok, _meta} = Manager.create_team(%{name: "cd", team_id: tid})

      test_pid = self()

      holder =
        spawn(fn ->
          send(
            test_pid,
            {:locked, NervousSystem.ConflictDetector.register_file_edit(tid, "a1", "lib/x.ex")}
          )

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:locked, :ok}, 2_000

      # Another agent is correctly blocked while the holder is alive.
      assert {:conflict, "a1"} =
               NervousSystem.ConflictDetector.register_file_edit(tid, "a2", "lib/x.ex")

      Process.exit(holder, :kill)

      assert eventually(fn ->
               NervousSystem.ConflictDetector.register_file_edit(tid, "a2", "lib/x.ex") == :ok
             end),
             "lock survived its holder — the path is blocked for the life of the team"

      Manager.dissolve_team(tid)
    end
  end

  defp eventually(fun, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
