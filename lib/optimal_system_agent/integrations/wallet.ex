defmodule OptimalSystemAgent.Integrations.Wallet do
  @moduledoc """
  Crypto wallet connectivity for on-chain operations.

  Supports multiple providers with a pluggable architecture.
  Default provider is :mock for testing and development.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  defstruct provider: :mock,
            address: nil,
            rpc_url: nil,
            cached_balance: nil,
            last_balance_check: nil,
            balance_cache_ttl: 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get current wallet balance (cached for 60s)."
  @spec get_balance() :: {:ok, map()} | {:error, String.t()}
  def get_balance do
    GenServer.call(__MODULE__, :get_balance)
  end

  @doc "Transfer funds to an address."
  @spec transfer(String.t(), float(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def transfer(to, amount, description) when is_binary(to) and is_number(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:transfer, to, amount, description}, 30_000)
  end

  @doc "Get transaction history."
  @spec transaction_history(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def transaction_history(opts \\ []) do
    GenServer.call(__MODULE__, {:transaction_history, opts})
  end

  @impl true
  def init(_opts) do
    provider =
      case Application.get_env(:optimal_system_agent, :wallet_provider, "mock") do
        "mock" -> :mock
        "base_usdc" -> :base_usdc
        "ethereum" -> :ethereum
        "solana" -> :solana
        other when is_atom(other) -> other
        _ -> :mock
      end

    state = %__MODULE__{
      provider: provider,
      address: Application.get_env(:optimal_system_agent, :wallet_address),
      rpc_url: Application.get_env(:optimal_system_agent, :wallet_rpc_url),
      balance_cache_ttl: 60
    }

    Logger.info(
      "[Wallet] Initialized with provider=#{provider} address=#{state.address || "none"}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_balance, _from, state) do
    if cache_fresh?(state) do
      {:reply, {:ok, state.cached_balance}, state}
    else
      case fetch_balance(state) do
        {:ok, balance} ->
          new_state = %{state | cached_balance: balance, last_balance_check: DateTime.utc_now()}

          {:reply, {:ok, balance}, new_state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call({:transfer, to, amount, description}, _from, state) do
    case do_transfer(state, to, amount, description) do
      {:ok, tx_hash} ->
        Bus.emit(:system_event, %{
          event: :wallet_transfer,
          to: to,
          amount: amount,
          tx_hash: tx_hash,
          provider: state.provider
        })

        # Invalidate balance cache
        {:reply, {:ok, tx_hash}, %{state | cached_balance: nil, last_balance_check: nil}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:transaction_history, opts}, _from, state) do
    result = fetch_history(state, opts)
    {:reply, result, state}
  end

  defp cache_fresh?(%{last_balance_check: nil}), do: false

  defp cache_fresh?(%{last_balance_check: last, balance_cache_ttl: ttl}) do
    DateTime.diff(DateTime.utc_now(), last, :second) < ttl
  end

  defp fetch_balance(%{provider: :mock}) do
    OptimalSystemAgent.Integrations.Wallet.Mock.get_balance()
  end

  defp fetch_balance(%{provider: provider}) do
    {:error, "Provider #{provider} not implemented"}
  end

  defp do_transfer(%{provider: :mock}, to, amount, description) do
    OptimalSystemAgent.Integrations.Wallet.Mock.transfer(to, amount, description)
  end

  defp do_transfer(%{provider: provider}, _to, _amount, _description) do
    {:error, "Provider #{provider} not implemented"}
  end

  defp fetch_history(%{provider: :mock}, opts) do
    OptimalSystemAgent.Integrations.Wallet.Mock.transaction_history(opts)
  end

  defp fetch_history(%{provider: provider}, _opts) do
    {:error, "Provider #{provider} not implemented"}
  end
end
