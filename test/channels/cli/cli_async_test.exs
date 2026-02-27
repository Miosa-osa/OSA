defmodule OptimalSystemAgent.Channels.CLI.AsyncTest do
  use ExUnit.Case, async: true

  # ── ETS Active Request Lifecycle ─────────────────────────────────

  describe "ETS active request lifecycle" do
    setup do
      table = :"cli_async_test_#{:rand.uniform(100_000)}"
      :ets.new(table, [:set, :public, :named_table])
      {:ok, table: table}
    end

    test "insert and lookup active request", %{table: table} do
      session_id = "test-session-#{:rand.uniform(100_000)}"
      request = %{request_id: 1, spinner: nil, tool_ref: nil, llm_ref: nil}
      :ets.insert(table, {session_id, request})

      assert [{^session_id, ^request}] = :ets.lookup(table, session_id)
    end

    test "delete clears active request", %{table: table} do
      session_id = "test-session-#{:rand.uniform(100_000)}"
      :ets.insert(table, {session_id, %{request_id: 1}})
      :ets.delete(table, session_id)

      assert [] = :ets.lookup(table, session_id)
    end

    test "lookup returns empty for unknown session", %{table: table} do
      assert [] = :ets.lookup(table, "unknown-session")
    end
  end

  # ── Agent Active Detection ──────────────────────────────────────

  describe "agent_active? equivalent" do
    setup do
      table = :"cli_active_test_#{:rand.uniform(100_000)}"
      :ets.new(table, [:set, :public, :named_table])
      {:ok, table: table}
    end

    test "returns true when request exists", %{table: table} do
      session_id = "active-session"
      :ets.insert(table, {session_id, %{request_id: 42}})

      active? = case :ets.lookup(table, session_id) do
        [{^session_id, _}] -> true
        _ -> false
      end

      assert active?
    end

    test "returns false when no request exists", %{table: table} do
      active? = case :ets.lookup(table, "no-such-session") do
        [{"no-such-session", _}] -> true
        _ -> false
      end

      refute active?
    end
  end

  # ── Stale Request ID Handling ────────────────────────────────────

  describe "stale request_id handling" do
    setup do
      table = :"cli_stale_test_#{:rand.uniform(100_000)}"
      :ets.new(table, [:set, :public, :named_table])
      {:ok, table: table}
    end

    test "mismatched request_id is ignored", %{table: table} do
      session_id = "stale-session"
      :ets.insert(table, {session_id, %{request_id: 100}})

      # Simulate a response with stale request_id
      stale_req_id = 99
      result = case :ets.lookup(table, session_id) do
        [{^session_id, %{request_id: ^stale_req_id}}] -> :handled
        _ -> :ignored
      end

      assert result == :ignored
      # Active request should still be there
      assert [{^session_id, _}] = :ets.lookup(table, session_id)
    end

    test "matching request_id is handled", %{table: table} do
      session_id = "current-session"
      :ets.insert(table, {session_id, %{request_id: 100}})

      current_req_id = 100
      result = case :ets.lookup(table, session_id) do
        [{^session_id, %{request_id: ^current_req_id}}] -> :handled
        _ -> :ignored
      end

      assert result == :handled
    end
  end

  # ── Cancel Clears State ──────────────────────────────────────────

  describe "cancel clears state" do
    setup do
      table = :"cli_cancel_test_#{:rand.uniform(100_000)}"
      :ets.new(table, [:set, :public, :named_table])
      {:ok, table: table}
    end

    test "deleting session clears active request", %{table: table} do
      session_id = "cancel-session"
      :ets.insert(table, {session_id, %{request_id: 1, spinner: nil, tool_ref: nil, llm_ref: nil}})

      # Simulate cancel: delete the entry
      :ets.delete(table, session_id)

      assert [] = :ets.lookup(table, session_id)
    end

    test "cancel is idempotent for missing session", %{table: table} do
      # Should not crash
      :ets.delete(table, "nonexistent")
      assert [] = :ets.lookup(table, "nonexistent")
    end
  end

  # ── Pending Plan Storage ─────────────────────────────────────────

  describe "pending plan storage" do
    setup do
      table = :"cli_plan_test_#{:rand.uniform(100_000)}"
      :ets.new(table, [:set, :public, :named_table])
      {:ok, table: table}
    end

    test "stores pending plan for session", %{table: table} do
      session_id = "plan-session"
      plan_text = "## Plan\n1. Do things\n2. Do more things"
      :ets.insert(table, {:pending_plan, session_id, plan_text, "original input"})

      assert [{:pending_plan, ^session_id, ^plan_text, "original input"}] =
               :ets.lookup(table, :pending_plan)
    end

    test "consuming plan removes it from ETS", %{table: table} do
      :ets.insert(table, {:pending_plan, "s1", "plan", "input"})
      :ets.delete(table, :pending_plan)

      assert [] = :ets.lookup(table, :pending_plan)
    end
  end
end
