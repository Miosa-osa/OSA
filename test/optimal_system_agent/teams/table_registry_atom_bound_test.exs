defmodule OptimalSystemAgent.Teams.TableRegistryAtomBoundTest do
  @moduledoc """
  `Teams.TableRegistry` must never mint atoms from team ids.

  This is the one unbounded-growth finding whose end state is an unrecoverable
  VM crash rather than a slowdown: atoms are never garbage collected and the
  atom table is a hard limit, so per-team dynamic names (`:"team_<id>_meta"`)
  meant a long-running daemon that creates and dissolves teams eventually aborts
  with `system_limit`.

  The bound is asserted directly: create hundreds of teams with distinct ids and
  assert `:erlang.system_info(:atom_count)` does not track the team count, and
  that `:ets.all/0` does not grow a table per team either.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Teams.AgentState
  alias OptimalSystemAgent.Teams.TableRegistry

  defp team_id, do: "atombound-#{System.unique_integer([:positive])}"

  describe "the bound: no atoms and no tables per team" do
    test "500 distinct teams do not grow the atom table with them" do
      ids = Enum.map(1..500, fn _ -> team_id() end)

      # Warm the shared tables and the code paths first, so what we measure is
      # purely the per-team cost.
      TableRegistry.ensure_tables(team_id())

      before_atoms = :erlang.system_info(:atom_count)
      before_tables = length(:ets.all())

      Enum.each(ids, fn id ->
        TableRegistry.ensure_tables(id)
        AgentState.put(id, AgentState.new("a1", "a1", "worker", "test-model"))
      end)

      grew_atoms = :erlang.system_info(:atom_count) - before_atoms
      grew_tables = length(:ets.all()) - before_tables

      # The old implementation created 2 atoms AND 2 tables per team: 1000 of
      # each here. A generous ceiling still fails loudly on any regression.
      assert grew_atoms < 100,
             "team ids must not become atoms — atom table grew by #{grew_atoms} over 500 teams"

      assert grew_tables < 10,
             "team storage must not be a table per team — ETS grew by #{grew_tables} tables"

      Enum.each(ids, &TableRegistry.destroy_tables/1)
    end

    test "creating and dissolving the same-shaped team repeatedly is atom-flat" do
      TableRegistry.ensure_tables(team_id())
      before_atoms = :erlang.system_info(:atom_count)

      Enum.each(1..300, fn _ ->
        id = team_id()
        TableRegistry.ensure_tables(id)
        AgentState.put(id, AgentState.new("a", "a", "worker", "test-model"))
        TableRegistry.destroy_tables(id)
      end)

      assert :erlang.system_info(:atom_count) - before_atoms < 100
    end
  end

  describe "behaviour is preserved through the key change" do
    setup do
      id = team_id()
      TableRegistry.ensure_tables(id)
      on_exit(fn -> TableRegistry.destroy_tables(id) end)
      {:ok, id: id}
    end

    test "presence tracking", %{id: id} do
      assert TableRegistry.tables_exist?(id)
      assert id in TableRegistry.list_live_teams()

      TableRegistry.destroy_tables(id)

      refute TableRegistry.tables_exist?(id)
      refute id in TableRegistry.list_live_teams()
    end

    test "an unknown team has no storage" do
      refute TableRegistry.tables_exist?("never-created-#{System.unique_integer([:positive])}")
    end

    test "agent state round-trips", %{id: id} do
      state = AgentState.new("agent-1", "agent-1", "worker", "test-model")
      assert :ok = AgentState.put(id, state)
      assert %AgentState{agent_id: "agent-1"} = AgentState.get(id, "agent-1")

      assert :ok = AgentState.delete(id, "agent-1")
      assert AgentState.get(id, "agent-1") == nil
    end

    test "list/1 is scoped to its own team", %{id: id} do
      other = team_id()
      TableRegistry.ensure_tables(other)
      on_exit(fn -> TableRegistry.destroy_tables(other) end)

      AgentState.put(id, AgentState.new("mine-1", "mine-1", "worker", "test-model"))
      AgentState.put(id, AgentState.new("mine-2", "mine-2", "worker", "test-model"))
      AgentState.put(other, AgentState.new("theirs", "theirs", "worker", "test-model"))

      mine = AgentState.list(id) |> Enum.map(& &1.agent_id) |> Enum.sort()
      assert mine == ["mine-1", "mine-2"], "shared storage must not leak across teams"

      assert AgentState.list(other) |> Enum.map(& &1.agent_id) == ["theirs"]
    end

    test "dissolution frees every row for the team and only that team", %{id: id} do
      other = team_id()
      TableRegistry.ensure_tables(other)
      on_exit(fn -> TableRegistry.destroy_tables(other) end)

      Enum.each(1..20, fn i ->
        AgentState.put(id, AgentState.new("a#{i}", "a#{i}", "worker", "test-model"))
        AgentState.put(other, AgentState.new("b#{i}", "b#{i}", "worker", "test-model"))
      end)

      assert TableRegistry.row_count(id) >= 20

      TableRegistry.destroy_tables(id)

      assert TableRegistry.row_count(id) == 0, "dissolution must free the team's storage"
      assert TableRegistry.row_count(other) >= 20
      assert AgentState.list(id) == []
    end

    test "destroying a team that never existed is a no-op" do
      assert :ok = TableRegistry.destroy_tables("ghost-#{System.unique_integer([:positive])}")
    end
  end
end
