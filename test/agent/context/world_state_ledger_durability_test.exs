defmodule OptimalSystemAgent.Agent.Context.WorldStateLedgerDurabilityTest do
  @moduledoc """
  The world-state ledger must outlive the process that first touched it.

  `WorldState` kept its ledger in a lazily created ETS table, and an ETS table
  belongs to the process that called `:ets.new/2`. `assemble/3` is reached from
  transient processes — an HTTP request process, a tool Task, a subagent Task —
  so whichever one got there first OWNED the table and destroyed it on exit,
  taking every session's digests and payloads with it.

  The symptom is the one `WorldStateSupersessionTest` intermittently caught
  under the full suite (another async test's process created the table, then
  finished): a section that changed reports `:added` instead of `:changed`, so
  the model is handed a second full copy of something already in its history
  with nothing saying the first copy is dead. That is not a test-isolation
  artifact — it is the product losing a turn's record, and these tests fail on
  the pre-fix code with the table lazily owned.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context.WorldState

  @table :osa_world_state_ledger

  # Deliberately NO setup that touches the ledger. `WorldState.reset/1` calls
  # `ensure_table/0`, so a reset here would create the table in the TEST
  # process and hand the spawned writer below a table that already exists —
  # hiding the very thing these tests exist to catch. Session ids are unique
  # per test, so there is nothing to reset.
  defp session, do: "ws-durability-#{System.unique_integer([:positive])}"

  test "the ledger table is owned by a long-lived process, not by its first caller" do
    owner = :ets.info(@table, :owner)

    refute owner == :undefined,
           "the ledger table does not exist at boot — it is created by whichever " <>
             "process touches it first, and dies with that process"

    assert Process.alive?(owner)

    refute owner == self(),
           "the ledger table is owned by the caller; it would be destroyed when this " <>
             "process exits, taking every session's ledger with it"
  end

  test "a turn assembled inside a short-lived process does not take the ledger with it" do
    session = session()
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        WorldState.assemble(session, [{"catalog v1", 1, "commands"}])
        send(parent, :assembled)
      end)

    assert_receive :assembled, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    {_parts, summary} = WorldState.assemble(session, [{"catalog v2", 1, "commands"}])

    assert summary.changes[:apps] == :changed,
           "the previous turn's record was lost when the process that wrote it exited — " <>
             "the section reports #{inspect(summary.changes[:apps])}, so the model gets a " <>
             "second full copy with no supersession notice"
  end

  test "the append-only prefix survives a short-lived writer" do
    session = session()
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {parts, _} = WorldState.assemble(session, [{"catalog v1", 1, "commands"}])
        send(parent, {:first, WorldState.text(parts)})
      end)

    assert_receive {:first, first}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    {parts, _} = WorldState.assemble(session, [{"catalog v2", 1, "commands"}])

    assert String.starts_with?(WorldState.text(parts), first),
           "the replayed ledger no longer begins with the previous turn's bytes, so the " <>
             "cached prefix breaks and the whole block re-prefills"
  end
end
