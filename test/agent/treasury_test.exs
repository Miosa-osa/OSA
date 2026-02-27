defmodule OptimalSystemAgent.Agent.TreasuryTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Treasury

  # Start a fresh Treasury per test to avoid shared state
  setup do
    name = :"treasury_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    {:ok, pid} =
      GenServer.start_link(
        Treasury,
        [
          balance: 1000.0,
          daily_limit: 250.0,
          monthly_limit: 2500.0,
          max_single: 50.0,
          min_reserve: 10.0,
          approval_threshold: 10.0
        ], name: name)

    %{pid: pid, name: name}
  end

  describe "deposit/2" do
    test "increases balance", %{pid: pid} do
      {:ok, txn} = GenServer.call(pid, {:deposit, 100.0, "Test deposit"})

      assert txn.type == :credit
      assert txn.amount_usd == 100.0
      assert txn.balance_after == 1100.0

      {:ok, balance} = GenServer.call(pid, :get_balance)
      assert balance.balance == 1100.0
    end
  end

  describe "withdraw/3" do
    test "decreases balance", %{pid: pid} do
      {:ok, txn} = GenServer.call(pid, {:withdraw, 25.0, "Test withdrawal", nil})

      assert txn.type == :debit
      assert txn.amount_usd == 25.0
      assert txn.balance_after == 975.0

      {:ok, balance} = GenServer.call(pid, :get_balance)
      assert balance.balance == 975.0
    end

    test "fails when exceeds daily limit", %{pid: pid} do
      # Withdraw multiple times to exceed daily_limit of 250 (max_single=50)
      {:ok, _} = GenServer.call(pid, {:withdraw, 50.0, "Withdrawal 1", nil})
      {:ok, _} = GenServer.call(pid, {:withdraw, 50.0, "Withdrawal 2", nil})
      {:ok, _} = GenServer.call(pid, {:withdraw, 50.0, "Withdrawal 3", nil})
      {:ok, _} = GenServer.call(pid, {:withdraw, 50.0, "Withdrawal 4", nil})
      {:ok, _} = GenServer.call(pid, {:withdraw, 50.0, "Withdrawal 5", nil})
      result = GenServer.call(pid, {:withdraw, 10.0, "Over daily limit", nil})

      assert {:error, reason} = result
      assert reason =~ "daily limit"
    end

    test "fails when exceeds max_single", %{pid: pid} do
      result = GenServer.call(pid, {:withdraw, 75.0, "Too large single", nil})

      assert {:error, reason} = result
      assert reason =~ "max single"
    end

    test "fails when would go below min_reserve", %{pid: pid} do
      # Balance is 1000, min_reserve is 10, so max withdrawal is 990
      # But daily limit is 250, so let's test with a smaller setup
      {:ok, low_pid} =
        GenServer.start_link(
          Treasury,
          [
            balance: 20.0,
            daily_limit: 250.0,
            monthly_limit: 2500.0,
            max_single: 50.0,
            min_reserve: 10.0
          ], name: :"treasury_low_#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}")

      result = GenServer.call(low_pid, {:withdraw, 15.0, "Below reserve", nil})

      assert {:error, reason} = result
      assert reason =~ "minimum reserve"
    end
  end

  describe "reserve/2 and release/1" do
    test "reserve holds funds", %{pid: pid} do
      {:ok, txn} = GenServer.call(pid, {:reserve, 100.0, "ref_hold_001"})

      assert txn.type == :reserve
      assert txn.amount_usd == 100.0

      {:ok, balance} = GenServer.call(pid, :get_balance)
      assert balance.reserved == 100.0
      assert balance.available == 900.0
    end

    test "release returns reserved funds", %{pid: pid} do
      {:ok, _} = GenServer.call(pid, {:reserve, 100.0, "ref_release_001"})
      {:ok, txn} = GenServer.call(pid, {:release, "ref_release_001"})

      assert txn.type == :release
      assert txn.amount_usd == 100.0

      {:ok, balance} = GenServer.call(pid, :get_balance)
      assert balance.reserved == 0.0
      assert balance.available == 1000.0
    end
  end

  describe "get_balance/0" do
    test "returns correct available amount", %{pid: pid} do
      {:ok, _} = GenServer.call(pid, {:reserve, 200.0, "ref_balance_test"})

      {:ok, balance} = GenServer.call(pid, :get_balance)

      assert balance.balance == 1000.0
      assert balance.reserved == 200.0
      assert balance.available == 800.0
    end
  end

  describe "needs_approval?/2" do
    test "returns true above threshold" do
      assert Treasury.needs_approval?(15.0, 10.0) == true
    end

    test "returns false at or below threshold" do
      assert Treasury.needs_approval?(10.0, 10.0) == false
      assert Treasury.needs_approval?(5.0, 10.0) == false
    end
  end

  describe "get_ledger/1" do
    test "returns transaction history", %{pid: pid} do
      {:ok, _} = GenServer.call(pid, {:deposit, 50.0, "Deposit 1"})
      {:ok, _} = GenServer.call(pid, {:withdraw, 20.0, "Withdraw 1", nil})

      {:ok, ledger} = GenServer.call(pid, {:get_ledger, []})

      assert length(ledger) == 2
      assert Enum.any?(ledger, &(&1.type == :credit))
      assert Enum.any?(ledger, &(&1.type == :debit))
    end

    test "filters by type", %{pid: pid} do
      {:ok, _} = GenServer.call(pid, {:deposit, 50.0, "Deposit"})
      {:ok, _} = GenServer.call(pid, {:withdraw, 20.0, "Withdraw", nil})

      {:ok, credits} = GenServer.call(pid, {:get_ledger, [type: :credit]})
      assert length(credits) == 1
      assert hd(credits).type == :credit
    end
  end
end
