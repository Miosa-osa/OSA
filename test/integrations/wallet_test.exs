defmodule OptimalSystemAgent.Integrations.WalletTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Integrations.Wallet.Mock

  setup do
    # Start the mock agent for each test
    case Process.whereis(Mock) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end

    {:ok, _} = Mock.start_link()
    :ok
  end

  describe "Mock.get_balance/0" do
    test "returns initial balance" do
      {:ok, balance} = Mock.get_balance()
      assert balance.balance == 1000.0
      assert balance.currency == "USDC"
    end
  end

  describe "Mock.transfer/3" do
    test "successful transfer reduces balance" do
      {:ok, tx_hash} = Mock.transfer("0xrecipient", 100.0, "test payment")
      assert is_binary(tx_hash)
      assert String.starts_with?(tx_hash, "mock_tx_")

      {:ok, balance} = Mock.get_balance()
      assert balance.balance == 900.0
    end

    test "insufficient balance returns error" do
      {:error, reason} = Mock.transfer("0xrecipient", 2000.0, "too much")
      assert reason =~ "Insufficient"
    end
  end

  describe "Mock.transaction_history/1" do
    test "empty initially" do
      {:ok, txs} = Mock.transaction_history()
      assert txs == []
    end

    test "records transactions" do
      {:ok, _} = Mock.transfer("0xrecipient", 50.0, "payment 1")
      {:ok, _} = Mock.transfer("0xother", 25.0, "payment 2")

      {:ok, txs} = Mock.transaction_history()
      assert length(txs) == 2
    end

    test "respects limit" do
      for i <- 1..5 do
        {:ok, _} = Mock.transfer("0xrecipient", 1.0, "payment #{i}")
      end

      {:ok, txs} = Mock.transaction_history(limit: 3)
      assert length(txs) == 3
    end
  end
end
