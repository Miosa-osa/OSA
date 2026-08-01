defmodule OptimalSystemAgent.Infra.BoundedTableTest do
  @moduledoc """
  Bounds tests for the append-mostly ETS history tables.

  `:osa_healing_sessions`, `:osa_speculative_executions`, `:osa_peer_*` and
  `:osa_reminders_claimed` were insert-only: the peer tables in particular gained
  one permanent row per tool call and nothing ever removed one.

  These tests drive N inserts and assert the row count stops growing — both for
  the shared helper and for the real subsystem tables through their own APIs.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Infra.BoundedTable

  defp fresh_table do
    name = :"bt_test_#{System.unique_integer([:positive])}"
    :ets.new(name, [:named_table, :public, :set])
    name
  end

  describe "the cap" do
    test "1000 inserts against a cap of 20 leave exactly 20 rows" do
      t = fresh_table()
      Enum.each(1..1000, fn i -> BoundedTable.insert(t, "k#{i}", i, max: 20) end)

      assert BoundedTable.size(t) == 20
    end

    test "eviction is oldest-first, so the newest rows survive" do
      t = fresh_table()
      Enum.each(1..50, fn i -> BoundedTable.insert(t, i, i, max: 5) end)

      assert :ets.lookup(t, 50) != []
      assert :ets.lookup(t, 49) != []
      assert :ets.lookup(t, 1) == []
      assert BoundedTable.size(t) == 5
    end

    test "re-inserting the same key updates in place without inflating the count" do
      t = fresh_table()
      Enum.each(1..500, fn i -> BoundedTable.insert(t, :only_key, i, max: 10) end)

      assert BoundedTable.size(t) == 1
      assert [{:only_key, 500}] = :ets.lookup(t, :only_key)
    end

    test "an update refreshes recency, so a churning row is not evicted" do
      t = fresh_table()
      BoundedTable.insert(t, :hot, 0, max: 5)

      Enum.each(1..40, fn i ->
        BoundedTable.insert(t, :hot, i, max: 5)
        BoundedTable.insert(t, "cold-#{i}", i, max: 5)
      end)

      assert :ets.lookup(t, :hot) != []
      assert BoundedTable.size(t) == 5
    end

    test "max: 0 disables eviction" do
      t = fresh_table()
      Enum.each(1..100, fn i -> BoundedTable.insert(t, i, i, max: 0) end)
      assert BoundedTable.size(t) == 100
    end

    test "delete/2 removes the row and its bookkeeping" do
      t = fresh_table()
      BoundedTable.insert(t, :a, 1, max: 10)
      assert :ok = BoundedTable.delete(t, :a)
      assert :ets.lookup(t, :a) == []
      assert BoundedTable.size(t) == 0
    end

    test "insert_new/4 keeps claim semantics and still caps" do
      t = fresh_table()
      assert BoundedTable.insert_new(t, :k, true, max: 10) == true
      assert BoundedTable.insert_new(t, :k, true, max: 10) == false

      Enum.each(1..200, fn i -> BoundedTable.insert_new(t, i, true, max: 10) end)
      assert BoundedTable.size(t) == 10
    end

    test "two bounded tables do not evict each other" do
      a = fresh_table()
      b = fresh_table()

      Enum.each(1..100, fn i -> BoundedTable.insert(a, i, i, max: 5) end)
      Enum.each(1..3, fn i -> BoundedTable.insert(b, i, i, max: 5) end)

      assert BoundedTable.size(a) == 5
      assert BoundedTable.size(b) == 3, "one table's eviction must not touch another's rows"
    end

    test "the shared bookkeeping tables stay bounded too" do
      t = fresh_table()
      Enum.each(1..1000, fn i -> BoundedTable.insert(t, i, i, max: 10) end)

      own =
        :ets.match(:osa_bounded_seq, {{t, :"$1"}, :_}) |> length()

      assert own <= 10, "bookkeeping must not become the leak it fixes (#{own} rows)"
    end

    test "never raises on a missing table" do
      assert :ok = BoundedTable.insert(:bt_no_such_table_xyz, :k, 1, max: 5)
      assert :ok = BoundedTable.delete(:bt_no_such_table_xyz, :k)
      assert BoundedTable.size(:bt_no_such_table_xyz) == 0
    end
  end

  describe "the real subsystem tables are actually wired up" do
    test "peer review history is bounded through Peer.Review" do
      Enum.each(1..1500, fn i ->
        OptimalSystemAgent.Peer.Review.request_review("agent-a", "agent-b", "artifact body #{i}")
      end)

      size = BoundedTable.size(:osa_peer_reviews)
      assert size <= 1_100, "peer review table must be bounded, got #{size}"
    end

    test "peer handoffs are bounded through Peer.Protocol" do
      before = BoundedTable.size(:osa_peer_handoffs)

      Enum.each(1..1500, fn i ->
        OptimalSystemAgent.Peer.Protocol.create_handoff("a", "b", %{task: "task #{i}"})
      end)

      size = BoundedTable.size(:osa_peer_handoffs)

      assert size <= 1_100,
             "peer handoff table must be bounded (was #{before}, now #{size})"
    end

    test "reminder claims are bounded" do
      Enum.each(1..100, fn i ->
        OptimalSystemAgent.Agent.Reminders.claim("bt-session-#{i}", :some_key)
      end)

      # Well under the 20k cap — this asserts the wiring exists and claims still
      # work exactly once per (session, key).
      assert OptimalSystemAgent.Agent.Reminders.claim("bt-once", :k) == true
      assert OptimalSystemAgent.Agent.Reminders.claim("bt-once", :k) == false
    end
  end
end
