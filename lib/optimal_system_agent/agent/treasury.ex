defmodule OptimalSystemAgent.Agent.Treasury do
  @moduledoc """
  Financial governance for agent operations.

  Manages a central balance with deposit, withdrawal, reservation, and release
  semantics. Enforces daily/monthly limits, max single transaction caps, and
  minimum reserve requirements.

  Limits default to environment variables or application config:
  - OSA_TREASURY_ENABLED (default false)
  - OSA_TREASURY_DAILY_LIMIT (default 250.0)
  - OSA_TREASURY_MONTHLY_LIMIT (default 2500.0)
  - OSA_TREASURY_MAX_SINGLE (default 50.0)
  - OSA_TREASURY_MIN_RESERVE (default 10.0)
  - OSA_TREASURY_APPROVAL_THRESHOLD (default 10.0)

  Events emitted on :system_event:
  - :treasury_deposit — when funds are deposited
  - :treasury_withdrawal — when funds are withdrawn
  - :treasury_reserve — when funds are reserved
  - :treasury_release — when reserved funds are released
  - :treasury_limit_exceeded — when a limit check fails
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  # ── State ────────────────────────────────────────────────────────────

  defstruct balance: 0.0,
            reserved: 0.0,
            daily_spent: 0.0,
            monthly_spent: 0.0,
            daily_limit: 250.0,
            monthly_limit: 2500.0,
            min_reserve: 10.0,
            max_single: 50.0,
            approval_threshold: 10.0,
            transactions: [],
            daily_reset_at: nil,
            monthly_reset_at: nil

  @daily_reset_ms 24 * 60 * 60 * 1000
  @monthly_reset_ms 30 * 24 * 60 * 60 * 1000

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Deposit funds into the treasury.

  Returns `{:ok, transaction}` with the created credit transaction.
  """
  def deposit(amount, description) when is_number(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:deposit, amount, description})
  end

  @doc """
  Withdraw funds from the treasury.

  Checks all limits (daily, monthly, max_single, min_reserve) before processing.
  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  def withdraw(amount, description, reference_id \\ nil) when is_number(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:withdraw, amount, description, reference_id})
  end

  @doc """
  Reserve (pre-authorize) funds. Moves amount from available to reserved.

  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  def reserve(amount, reference_id) when is_number(amount) and amount > 0 do
    GenServer.call(__MODULE__, {:reserve, amount, reference_id})
  end

  @doc """
  Release reserved funds back to available balance.

  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  def release(reference_id) when is_binary(reference_id) do
    GenServer.call(__MODULE__, {:release, reference_id})
  end

  @doc """
  Get current balance information.

  Returns `{:ok, %{balance, reserved, available}}`.
  """
  def get_balance do
    GenServer.call(__MODULE__, :get_balance)
  end

  @doc """
  Check if an amount requires approval.

  Pure function — does not call the GenServer.
  """
  @spec needs_approval?(number(), number()) :: boolean()
  def needs_approval?(amount, threshold \\ 10.0) do
    amount > threshold
  end

  @doc """
  Get the transaction ledger.

  ## Options
  - `:type` — filter by transaction type (:credit, :debit, :reserve, :release)
  - `:since` — filter transactions after this DateTime
  - `:limit` — max number of transactions to return
  """
  def get_ledger(opts \\ []) do
    GenServer.call(__MODULE__, {:get_ledger, opts})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    daily_limit =
      parse_float_env(
        "OSA_TREASURY_DAILY_LIMIT",
        Keyword.get(
          opts,
          :daily_limit,
          Application.get_env(:optimal_system_agent, :treasury_daily_limit, 250.0)
        )
      )

    monthly_limit =
      parse_float_env(
        "OSA_TREASURY_MONTHLY_LIMIT",
        Keyword.get(
          opts,
          :monthly_limit,
          Application.get_env(:optimal_system_agent, :treasury_monthly_limit, 2500.0)
        )
      )

    max_single =
      parse_float_env(
        "OSA_TREASURY_MAX_SINGLE",
        Keyword.get(
          opts,
          :max_single,
          Application.get_env(:optimal_system_agent, :treasury_max_single, 50.0)
        )
      )

    min_reserve =
      parse_float_env(
        "OSA_TREASURY_MIN_RESERVE",
        Keyword.get(
          opts,
          :min_reserve,
          Application.get_env(:optimal_system_agent, :treasury_min_reserve, 10.0)
        )
      )

    approval_threshold =
      parse_float_env(
        "OSA_TREASURY_APPROVAL_THRESHOLD",
        Keyword.get(
          opts,
          :approval_threshold,
          Application.get_env(:optimal_system_agent, :treasury_approval_threshold, 10.0)
        )
      )

    initial_balance = Keyword.get(opts, :balance, 0.0)

    now = DateTime.utc_now()

    state = %__MODULE__{
      balance: initial_balance,
      daily_limit: daily_limit,
      monthly_limit: monthly_limit,
      max_single: max_single,
      min_reserve: min_reserve,
      approval_threshold: approval_threshold,
      daily_reset_at: DateTime.add(now, @daily_reset_ms, :millisecond),
      monthly_reset_at: DateTime.add(now, @monthly_reset_ms, :millisecond)
    }

    schedule_daily_reset()
    schedule_monthly_reset()

    # Auto-debit: listen for Budget cost events and withdraw from Treasury.
    # Wrapped in try/catch — Bus may be unavailable during test suite or startup.
    if Application.get_env(:optimal_system_agent, :treasury_auto_debit, true) do
      try do
        Bus.register_handler(:system_event, fn payload ->
          case payload do
            %{event: :cost_recorded, cost_usd: amount}
            when is_number(amount) and amount > 0 ->
              try do
                GenServer.call(
                  __MODULE__,
                  {:withdraw, amount,
                   "API cost: #{payload[:provider]}/#{payload[:model]}",
                   payload[:entry_id]},
                  1_000
                )
              catch
                :exit, reason ->
                  Logger.warning("[Treasury] Auto-debit exit: #{inspect(reason)}")
              end

            _ ->
              :ok
          end
        end)
      catch
        :exit, reason ->
          Logger.warning("[Treasury] Could not register auto-debit handler: #{inspect(reason)}")
      end
    end

    Logger.info(
      "[Agent.Treasury] Started — daily: $#{daily_limit}, monthly: $#{monthly_limit}, " <>
        "max_single: $#{max_single}, min_reserve: $#{min_reserve}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:deposit, amount, description}, _from, state) do
    new_balance = state.balance + amount

    txn = create_transaction(:credit, amount, description, nil, new_balance)

    state = %{state | balance: new_balance, transactions: Enum.take([txn | state.transactions], 10_000)}

    Bus.emit(:system_event, %{event: :treasury_deposit, amount: amount, balance: new_balance})

    Logger.debug(
      "[Agent.Treasury] Deposit $#{Float.round(amount, 2)} — balance: $#{Float.round(new_balance, 2)}"
    )

    {:reply, {:ok, txn}, state}
  end

  @impl true
  def handle_call({:withdraw, amount, description, reference_id}, _from, state) do
    available = state.balance - state.reserved

    cond do
      amount > state.max_single ->
        Bus.emit(:system_event, %{
          event: :treasury_limit_exceeded,
          type: :max_single,
          amount: amount,
          limit: state.max_single
        })

        {:reply,
         {:error,
          "Amount $#{amount} exceeds max single transaction limit of $#{state.max_single}"},
         state}

      state.daily_spent + amount > state.daily_limit ->
        Bus.emit(:system_event, %{
          event: :treasury_limit_exceeded,
          type: :daily,
          amount: amount,
          limit: state.daily_limit
        })

        {:reply,
         {:error,
          "Would exceed daily limit of $#{state.daily_limit} (spent: $#{Float.round(state.daily_spent, 2)})"},
         state}

      state.monthly_spent + amount > state.monthly_limit ->
        Bus.emit(:system_event, %{
          event: :treasury_limit_exceeded,
          type: :monthly,
          amount: amount,
          limit: state.monthly_limit
        })

        {:reply,
         {:error,
          "Would exceed monthly limit of $#{state.monthly_limit} (spent: $#{Float.round(state.monthly_spent, 2)})"},
         state}

      available - amount < state.min_reserve ->
        Bus.emit(:system_event, %{
          event: :treasury_limit_exceeded,
          type: :min_reserve,
          amount: amount,
          available: available
        })

        {:reply,
         {:error,
          "Would go below minimum reserve of $#{state.min_reserve} (available: $#{Float.round(available, 2)})"},
         state}

      true ->
        new_balance = state.balance - amount
        new_daily = state.daily_spent + amount
        new_monthly = state.monthly_spent + amount

        txn = create_transaction(:debit, amount, description, reference_id, new_balance)

        state = %{
          state
          | balance: new_balance,
            daily_spent: new_daily,
            monthly_spent: new_monthly,
            transactions: Enum.take([txn | state.transactions], 10_000)
        }

        Bus.emit(:system_event, %{
          event: :treasury_withdrawal,
          amount: amount,
          balance: new_balance
        })

        Logger.debug(
          "[Agent.Treasury] Withdrawal $#{Float.round(amount, 2)} — " <>
            "balance: $#{Float.round(new_balance, 2)}, daily: $#{Float.round(new_daily, 2)}"
        )

        {:reply, {:ok, txn}, state}
    end
  end

  @impl true
  def handle_call({:reserve, amount, reference_id}, _from, state) do
    available = state.balance - state.reserved

    if available >= amount do
      new_reserved = state.reserved + amount

      txn = create_transaction(:reserve, amount, "Reserve hold", reference_id, state.balance)

      state = %{state | reserved: new_reserved, transactions: Enum.take([txn | state.transactions], 10_000)}

      Bus.emit(:system_event, %{
        event: :treasury_reserve,
        amount: amount,
        reference_id: reference_id
      })

      Logger.debug("[Agent.Treasury] Reserved $#{Float.round(amount, 2)} (ref: #{reference_id})")

      {:reply, {:ok, txn}, state}
    else
      {:reply,
       {:error,
        "Insufficient available funds ($#{Float.round(available, 2)}) to reserve $#{amount}"},
       state}
    end
  end

  @impl true
  def handle_call({:release, reference_id}, _from, state) do
    # Find the most recent reserve transaction for this reference_id
    case Enum.find(state.transactions, fn txn ->
           txn.type == :reserve and txn.reference_id == reference_id
         end) do
      nil ->
        {:reply, {:error, "No reservation found for reference: #{reference_id}"}, state}

      reserve_txn ->
        new_reserved = max(0.0, state.reserved - reserve_txn.amount_usd)

        txn =
          create_transaction(
            :release,
            reserve_txn.amount_usd,
            "Release hold",
            reference_id,
            state.balance
          )

        state = %{state | reserved: new_reserved, transactions: Enum.take([txn | state.transactions], 10_000)}

        Bus.emit(:system_event, %{
          event: :treasury_release,
          amount: reserve_txn.amount_usd,
          reference_id: reference_id
        })

        Logger.debug(
          "[Agent.Treasury] Released $#{Float.round(reserve_txn.amount_usd, 2)} (ref: #{reference_id})"
        )

        {:reply, {:ok, txn}, state}
    end
  end

  @impl true
  def handle_call(:get_balance, _from, state) do
    result = %{
      balance: Float.round(state.balance, 2),
      reserved: Float.round(state.reserved, 2),
      available: Float.round(state.balance - state.reserved, 2)
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:get_ledger, opts}, _from, state) do
    type_filter = Keyword.get(opts, :type)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit)

    txns = state.transactions
    txns = if type_filter, do: Enum.filter(txns, &(&1.type == type_filter)), else: txns

    txns =
      if since,
        do: Enum.filter(txns, &(DateTime.compare(&1.created_at, since) != :lt)),
        else: txns

    txns = if limit, do: Enum.take(txns, limit), else: txns

    {:reply, {:ok, txns}, state}
  end

  @impl true
  def handle_info(:reset_daily, state) do
    Logger.info(
      "[Agent.Treasury] Scheduled daily reset (was $#{Float.round(state.daily_spent, 2)})"
    )

    state = %{
      state
      | daily_spent: 0.0,
        daily_reset_at: DateTime.add(DateTime.utc_now(), @daily_reset_ms, :millisecond)
    }

    schedule_daily_reset()
    {:noreply, state}
  end

  @impl true
  def handle_info(:reset_monthly, state) do
    Logger.info(
      "[Agent.Treasury] Scheduled monthly reset (was $#{Float.round(state.monthly_spent, 2)})"
    )

    state = %{
      state
      | monthly_spent: 0.0,
        monthly_reset_at: DateTime.add(DateTime.utc_now(), @monthly_reset_ms, :millisecond)
    }

    schedule_monthly_reset()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp create_transaction(type, amount, description, reference_id, balance_after) do
    %{
      id: "txn_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)),
      type: type,
      amount_usd: amount,
      description: description,
      reference_id: reference_id,
      balance_after: Float.round(balance_after, 2),
      created_at: DateTime.utc_now()
    }
  end

  defp schedule_daily_reset do
    Process.send_after(self(), :reset_daily, @daily_reset_ms)
  end

  defp schedule_monthly_reset do
    Process.send_after(self(), :reset_monthly, @monthly_reset_ms)
  end

  defp parse_float_env(env_var, default) do
    case System.get_env(env_var) do
      nil ->
        default

      val ->
        case Float.parse(val) do
          {f, _} -> f
          :error -> default
        end
    end
  end
end
