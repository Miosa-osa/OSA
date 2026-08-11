defmodule OptimalSystemAgent.Budget.TreasuryReserveTest do
  @moduledoc """
  `{:reserve, amount, ref}` moves money out of `balance` exactly like a
  withdrawal, but ran with NONE of the four guards `{:withdraw, …}` runs and no
  lazy reset — so the balance could be driven arbitrarily negative and straight
  through `min_reserve`.

  It also blind-overwrote `reserves[ref]` after having already incremented
  `state.reserved`, so a second reserve under the same ref orphaned the first
  amount permanently: `{:release, ref}` can only return the second.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Budget.Treasury

  defp start_treasury(opts) do
    name = :"treasury_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Treasury, opts, name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  describe "reserve runs the same guards as withdraw" do
    test "refuses to breach the minimum reserve" do
      t = start_treasury(balance: 100.0, min_reserve: 40.0)

      assert {:error, reason} = GenServer.call(t, {:reserve, 80.0, "r1"})
      assert reason =~ "minimum reserve"

      assert {:ok, balance} = GenServer.call(t, :get_balance)
      assert balance.available == 100.0
    end

    test "refuses to drive the balance negative" do
      t = start_treasury(balance: 10.0)

      assert {:error, _} = GenServer.call(t, {:reserve, 1_000.0, "r1"})

      assert {:ok, balance} = GenServer.call(t, :get_balance)
      assert balance.available == 10.0
      assert balance.reserved == 0.0
    end

    test "does NOT apply the max-single WITHDRAWAL cap — a reserve is not a spend" do
      t = start_treasury(balance: 1_000.0, max_single: 50.0)

      assert {:ok, _} = GenServer.call(t, {:reserve, 200.0, "r1"})
    end

    test "does NOT charge the daily limit — that is measured on daily_spent" do
      t = start_treasury(balance: 1_000.0, daily_limit: 50.0)

      assert {:ok, _} = GenServer.call(t, {:reserve, 200.0, "r1"})
    end

    test "a reserve within the guards still succeeds" do
      t = start_treasury(balance: 100.0, min_reserve: 10.0)

      assert {:ok, txn} = GenServer.call(t, {:reserve, 50.0, "r1"})
      assert txn.type == :reserve

      assert {:ok, balance} = GenServer.call(t, :get_balance)
      assert balance.available == 50.0
      assert balance.reserved == 50.0
      assert balance.balance == 100.0
    end
  end

  describe "duplicate reserve refs" do
    test "a second reserve under the same ref is rejected, not silently orphaned" do
      t = start_treasury(balance: 100.0)

      assert {:ok, _} = GenServer.call(t, {:reserve, 30.0, "dup"})
      assert {:error, reason} = GenServer.call(t, {:reserve, 20.0, "dup"})
      assert reason =~ "already exists"

      # Releasing returns the ONE reserve in full, and `reserved` returns to 0.
      assert {:ok, _} = GenServer.call(t, {:release, "dup"})

      assert {:ok, balance} = GenServer.call(t, :get_balance)

      assert balance.reserved == 0.0,
             "part of a duplicated reserve stayed permanently orphaned in `reserved`"

      assert balance.available == 100.0
    end
  end
end
