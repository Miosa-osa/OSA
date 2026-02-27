defmodule OptimalSystemAgent.Tools.Builtins.WalletOps do
  @moduledoc "Wallet operations tool — check balance, send payments, view history."

  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Integrations.Wallet

  @impl true
  def name, do: "wallet_ops"

  @impl true
  def description, do: "Check wallet balance and send payments"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "description" => "Action to perform: check_balance, send_payment, history",
          "enum" => ["check_balance", "send_payment", "history"]
        },
        "to" => %{
          "type" => "string",
          "description" => "Recipient address (required for send_payment)"
        },
        "amount" => %{
          "type" => "number",
          "description" => "Amount to send (required for send_payment)"
        },
        "description" => %{
          "type" => "string",
          "description" => "Payment description"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "check_balance"}) do
    case Wallet.get_balance() do
      {:ok, balance} ->
        {:ok, "Wallet Balance: #{balance.balance} #{balance.currency} (#{balance.network})"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{"action" => "send_payment", "to" => to, "amount" => amount} = args)
      when is_binary(to) and is_number(amount) do
    description = Map.get(args, "description", "Payment via OSA")

    case Wallet.transfer(to, amount, description) do
      {:ok, tx_hash} ->
        {:ok, "Payment sent! TX: #{tx_hash} | #{amount} to #{to}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{"action" => "send_payment"}) do
    {:error, "send_payment requires 'to' (string) and 'amount' (number)"}
  end

  def execute(%{"action" => "history"}) do
    case Wallet.transaction_history() do
      {:ok, txs} ->
        if txs == [] do
          {:ok, "No transactions found."}
        else
          formatted =
            Enum.map_join(txs, "\n", fn tx ->
              "#{tx.timestamp} | #{tx.amount} to #{tx.to} | #{tx.hash}"
            end)

          {:ok, "Transaction History:\n#{formatted}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Valid actions: check_balance, send_payment, history"}
  end

  def execute(_) do
    {:error, "Missing required field: action"}
  end
end
