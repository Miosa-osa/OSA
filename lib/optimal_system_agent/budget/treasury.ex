defmodule OptimalSystemAgent.Budget.Treasury do
  @moduledoc """
  Treasury GenServer — reserve/release accounting with spend-limit enforcement.

  The Treasury manages a budget ledger with configurable guards:

  * **Daily limit** — maximum total debits in a 24-hour window
  * **Monthly limit** — maximum total debits in a calendar month
  * **Max single** — maximum amount for a single withdrawal
  * **Min reserve** — minimum balance that must remain after any withdrawal
  * **Approval threshold** — amounts above this require explicit approval

  Started opt-in via `OSA_TREASURY_ENABLED=true`:

      config :optimal_system_agent, treasury_enabled: true

  ## GenServer call protocol

      {:deposit,  amount, reason}       -> {:ok, txn}
      {:withdraw, amount, reason, ref}  -> {:ok, txn} | {:error, reason_string}
      {:reserve,  amount, ref}          -> {:ok, txn}
      {:release,  ref}                  -> {:ok, txn} | {:error, reason_string}
      :get_balance                      -> {:ok, balance_map}
      {:get_ledger, opts}               -> {:ok, [txn]}

  ## Pure helpers

      Treasury.needs_approval?(amount, threshold) -> boolean
  """

  use GenServer
  require Logger

  @type txn :: %{
          id: String.t(),
          type: :credit | :debit | :reserve | :release,
          amount_usd: float(),
          reason: String.t(),
          ref: String.t() | nil,
          balance_after: float(),
          recorded_at: DateTime.t()
        }

  @type balance :: %{
          balance: float(),
          reserved: float(),
          available: float()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return `true` when `amount` exceeds the approval `threshold`."
  @spec needs_approval?(float(), float()) :: boolean()
  def needs_approval?(amount, threshold) when is_number(amount) and is_number(threshold) do
    amount > threshold
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      balance: Keyword.get(opts, :balance, 0.0) * 1.0,
      reserved: 0.0,
      daily_spent: 0.0,
      monthly_spent: 0.0,
      daily_limit: Keyword.get(opts, :daily_limit, :infinity),
      monthly_limit: Keyword.get(opts, :monthly_limit, :infinity),
      max_single: Keyword.get(opts, :max_single, :infinity),
      min_reserve: Keyword.get(opts, :min_reserve, 0.0) * 1.0,
      approval_threshold: Keyword.get(opts, :approval_threshold, :infinity),
      # Map from ref string to reserved amount (for release)
      reserves: %{},
      ledger: [],
      daily_reset_at: tomorrow_midnight(),
      monthly_reset_at: next_month_midnight()
    }

    Logger.info("[Budget.Treasury] started — balance: #{state.balance}")
    {:ok, state}
  end

  @impl true
  def handle_call({:deposit, amount, reason}, _from, state) do
    amount = amount * 1.0
    new_balance = state.balance + amount
    txn = make_txn(:credit, amount, reason, nil, new_balance)
    state = %{state | balance: new_balance, ledger: [txn | state.ledger]}
    {:reply, {:ok, txn}, state}
  end

  @impl true
  def handle_call({:withdraw, amount, reason, ref}, _from, state) do
    state = maybe_reset(state)
    amount = amount * 1.0

    with :ok <- check_max_single(amount, state),
         :ok <- check_daily_limit(amount, state),
         :ok <- check_monthly_limit(amount, state),
         :ok <- check_min_reserve(amount, state) do
      new_balance = state.balance - amount
      txn = make_txn(:debit, amount, reason, ref, new_balance)

      state = %{
        state
        | balance: new_balance,
          daily_spent: state.daily_spent + amount,
          monthly_spent: state.monthly_spent + amount,
          ledger: [txn | state.ledger]
      }

      {:reply, {:ok, txn}, state}
    else
      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:reserve, amount, ref}, _from, state) do
    amount = amount * 1.0
    new_balance = state.balance - amount
    new_reserved = state.reserved + amount
    txn = make_txn(:reserve, amount, "reserve:#{ref}", ref, new_balance)

    state = %{
      state
      | balance: new_balance,
        reserved: new_reserved,
        reserves: Map.put(state.reserves, to_string(ref), amount),
        ledger: [txn | state.ledger]
    }

    {:reply, {:ok, txn}, state}
  end

  @impl true
  def handle_call({:release, ref}, _from, state) do
    ref_str = to_string(ref)

    case Map.get(state.reserves, ref_str) do
      nil ->
        {:reply, {:error, "no reserve found for ref: #{ref}"}, state}

      amount ->
        new_balance = state.balance + amount
        new_reserved = state.reserved - amount
        txn = make_txn(:release, amount, "release:#{ref}", ref_str, new_balance)

        state = %{
          state
          | balance: new_balance,
            reserved: new_reserved,
            reserves: Map.delete(state.reserves, ref_str),
            ledger: [txn | state.ledger]
        }

        {:reply, {:ok, txn}, state}
    end
  end

  @impl true
  def handle_call(:get_balance, _from, state) do
    state = maybe_reset(state)

    balance = %{
      balance: state.balance + state.reserved,
      reserved: state.reserved,
      available: state.balance
    }

    {:reply, {:ok, balance}, state}
  end

  @impl true
  def handle_call({:get_ledger, opts}, _from, state) do
    entries =
      case Keyword.get(opts, :type) do
        nil -> state.ledger
        type -> Enum.filter(state.ledger, &(&1.type == type))
      end

    {:reply, {:ok, Enum.reverse(entries)}, state}
  end

  @impl true
  def handle_call(:audit_log, _from, state) do
    {:reply, {:ok, state.ledger}, state}
  end

  # ---------------------------------------------------------------------------
  # Private — validation guards
  # ---------------------------------------------------------------------------

  defp check_max_single(_amount, %{max_single: :infinity}), do: :ok

  defp check_max_single(amount, %{max_single: max}) do
    if amount > max do
      {:error, "exceeds max single withdrawal of #{max}"}
    else
      :ok
    end
  end

  defp check_daily_limit(_amount, %{daily_limit: :infinity}), do: :ok

  defp check_daily_limit(amount, %{daily_spent: spent, daily_limit: limit}) do
    if spent + amount > limit do
      {:error, "exceeds daily limit of #{limit} (spent: #{spent})"}
    else
      :ok
    end
  end

  defp check_monthly_limit(_amount, %{monthly_limit: :infinity}), do: :ok

  defp check_monthly_limit(amount, %{monthly_spent: spent, monthly_limit: limit}) do
    if spent + amount > limit do
      {:error, "exceeds monthly limit of #{limit} (spent: #{spent})"}
    else
      :ok
    end
  end

  defp check_min_reserve(amount, %{balance: balance, min_reserve: min}) do
    if balance - amount < min do
      {:error, "withdrawal would breach minimum reserve of #{min}"}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private — lazy reset
  # ---------------------------------------------------------------------------

  defp maybe_reset(state) do
    now = DateTime.utc_now()
    state |> maybe_reset_daily(now) |> maybe_reset_monthly(now)
  end

  defp maybe_reset_daily(state, now) do
    if DateTime.compare(now, state.daily_reset_at) == :gt do
      %{state | daily_spent: 0.0, daily_reset_at: tomorrow_midnight()}
    else
      state
    end
  end

  defp maybe_reset_monthly(state, now) do
    if DateTime.compare(now, state.monthly_reset_at) == :gt do
      %{state | monthly_spent: 0.0, monthly_reset_at: next_month_midnight()}
    else
      state
    end
  end

  defp tomorrow_midnight do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
  end

  defp next_month_midnight do
    today = Date.utc_today()

    {year, month} =
      if today.month == 12, do: {today.year + 1, 1}, else: {today.year, today.month + 1}

    Date.new!(year, month, 1)
    |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
  end

  # ---------------------------------------------------------------------------
  # Private — transaction builder
  # ---------------------------------------------------------------------------

  defp make_txn(type, amount, reason, ref, balance_after) do
    %{
      id: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      type: type,
      amount_usd: amount,
      reason: reason,
      ref: ref && to_string(ref),
      balance_after: balance_after,
      recorded_at: DateTime.utc_now()
    }
  end
end
