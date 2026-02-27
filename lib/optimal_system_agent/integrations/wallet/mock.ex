defmodule OptimalSystemAgent.Integrations.Wallet.Mock do
  @moduledoc """
  Mock wallet provider for testing and development.

  Maintains an in-memory balance and transaction list via an Agent.
  Initial balance: 1000.0 USDC.
  """

  use Agent

  @initial_balance 1000.0

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          balance: @initial_balance,
          transactions: []
        }
      end,
      name: __MODULE__
    )
  end

  def get_balance do
    try do
      state = Agent.get(__MODULE__, & &1)

      {:ok,
       %{
         balance: state.balance,
         currency: "USDC",
         network: "mock",
         updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    catch
      :exit, _ ->
        {:ok,
         %{
           balance: @initial_balance,
           currency: "USDC",
           network: "mock",
           updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}
    end
  end

  def transfer(to, amount, description) do
    try do
      Agent.get_and_update(__MODULE__, fn state ->
        if amount > state.balance do
          {{:error, "Insufficient balance: #{state.balance} < #{amount}"}, state}
        else
          tx_hash = "mock_tx_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

          tx = %{
            hash: tx_hash,
            to: to,
            amount: amount,
            description: description,
            status: "confirmed",
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          }

          new_state = %{
            state
            | balance: state.balance - amount,
              transactions: [tx | state.transactions]
          }

          {{:ok, tx_hash}, new_state}
        end
      end)
    catch
      :exit, _ -> {:error, "Mock wallet not started"}
    end
  end

  def transaction_history(opts \\ []) do
    try do
      limit = Keyword.get(opts, :limit, 50)
      transactions = Agent.get(__MODULE__, & &1.transactions)
      {:ok, Enum.take(transactions, limit)}
    catch
      :exit, _ -> {:ok, []}
    end
  end
end
