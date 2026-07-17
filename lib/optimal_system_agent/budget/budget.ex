defmodule OptimalSystemAgent.Budget do
  @moduledoc """
  Budget GenServer — token/cost tracking with daily and monthly limits.

  Tracks provider API spend across sessions. When started from the supervisor,
  limits come from application env:

      config :optimal_system_agent,
        daily_budget_usd: 50.0,
        monthly_budget_usd: 200.0

  When started directly (e.g. in tests), limits can be passed as keyword opts:

      GenServer.start_link(Budget, [daily_limit: 10.0, monthly_limit: 100.0], name: name)

  ## Provider pricing

  Costs are computed with per-provider rates (USD per token):

  | Provider    | Input $/1M | Output $/1M |
  |-------------|-----------|------------|
  | `:anthropic` | 3.0       | 15.0       |
  | `:openai`    | 2.5       | 10.0       |
  | `:groq`      | 0.5       | 0.8        |
  | `:ollama`    | 0.0       | 0.0        |
  | default      | 1.0       | 3.0        |

  ## Daily / monthly reset

  Resets are lazy: they happen the first time `check_budget` or `get_status`
  is called after the reset deadline.
  """

  use GenServer
  require Logger

  @daily_default_usd 50.0
  @monthly_default_usd 200.0

  # USD per 1M tokens — {input_rate, output_rate}
  @provider_rates %{
    anthropic: {3.0, 15.0},
    openai: {2.5, 10.0},
    groq: {0.5, 0.8},
    ollama: {0.0, 0.0},
    default: {1.0, 3.0}
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Check whether spend is within limits. Returns `{:ok, remaining}` or `{:over_limit, period}`."
  @spec check_budget() :: {:ok, map()} | {:over_limit, :daily | :monthly}
  def check_budget do
    GenServer.call(__MODULE__, :check_budget)
  end

  @doc "Return full budget status including limits, spent, and reset times."
  @spec get_status() :: {:ok, map()}
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc "Record an API call cost. Fire-and-forget."
  @spec record_cost(atom(), String.t(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def record_cost(provider, model, tokens_in, tokens_out, session_id) do
    GenServer.cast(__MODULE__, {:record_cost, provider, model, tokens_in, tokens_out, session_id})
  end

  @doc """
  Calculate cost in USD for a given provider and token counts.

  Ollama always returns 0.0. Unknown providers use a conservative default rate.
  """
  @spec calculate_cost(atom(), non_neg_integer(), non_neg_integer()) :: float()
  def calculate_cost(provider, tokens_in, tokens_out) do
    {input_rate, output_rate} =
      Map.get(@provider_rates, provider, Map.fetch!(@provider_rates, :default))

    tokens_in / 1_000_000 * input_rate + tokens_out / 1_000_000 * output_rate
  end

  @doc """
  True when `provider` has an explicit, non-zero USD per-token rate — i.e. real
  cost data exists so spend can actually be nonzero.

  Providers without an explicit entry (e.g. GLM/zhipu) and zero-rate providers
  (Ollama) return false: for these the daily spend is always $0, so a status
  line should surface token usage instead of a meaningless "$0" figure. The
  generic default rate used by `calculate_cost/3` for estimation does NOT count
  as real pricing here.
  """
  @spec has_usd_pricing?(atom() | String.t()) :: boolean()
  def has_usd_pricing?(provider) when is_atom(provider) do
    case Map.get(@provider_rates, provider) do
      {input_rate, output_rate} when input_rate > 0 or output_rate > 0 -> true
      _ -> false
    end
  end

  def has_usd_pricing?(provider) when is_binary(provider) do
    case safe_existing_atom(provider) do
      nil -> false
      atom -> has_usd_pricing?(atom)
    end
  end

  def has_usd_pricing?(_), do: false

  defp safe_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  @doc "Manually reset the daily counter."
  def reset_daily do
    GenServer.cast(__MODULE__, :reset_daily)
  end

  @doc "Manually reset the monthly counter."
  def reset_monthly do
    GenServer.cast(__MODULE__, :reset_monthly)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) when is_list(opts) do
    state = %{
      daily_spent: 0.0,
      monthly_spent: 0.0,
      # Token counters (input + output) accumulated over the current day/month.
      # These are meaningful even when USD spend is $0 (e.g. providers without
      # per-token pricing such as GLM/Ollama), so the status line can show usage.
      daily_tokens: 0,
      monthly_tokens: 0,
      daily_limit:
        Keyword.get(opts, :daily_limit) ||
          Application.get_env(:optimal_system_agent, :daily_budget_usd, @daily_default_usd),
      monthly_limit:
        Keyword.get(opts, :monthly_limit) ||
          Application.get_env(:optimal_system_agent, :monthly_budget_usd, @monthly_default_usd),
      per_call_limit: Keyword.get(opts, :per_call_limit),
      entries: [],
      daily_reset_at: tomorrow_midnight(),
      monthly_reset_at: next_month_midnight()
    }

    Logger.info(
      "[Budget] started — daily: $#{state.daily_limit}, monthly: $#{state.monthly_limit}"
    )

    {:ok, state}
  end

  def init(:ok), do: init([])

  @impl true
  def handle_call(:check_budget, _from, state) do
    state = maybe_reset(state)
    daily_remaining = max(0.0, state.daily_limit - state.daily_spent)
    monthly_remaining = max(0.0, state.monthly_limit - state.monthly_spent)

    result =
      cond do
        state.daily_spent >= state.daily_limit ->
          {:over_limit, :daily}

        state.monthly_spent >= state.monthly_limit ->
          {:over_limit, :monthly}

        true ->
          {:ok, %{daily_remaining: daily_remaining, monthly_remaining: monthly_remaining}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    state = maybe_reset(state)

    status = %{
      daily_limit: state.daily_limit,
      monthly_limit: state.monthly_limit,
      per_call_limit: state.per_call_limit,
      daily_spent: state.daily_spent,
      monthly_spent: state.monthly_spent,
      daily_tokens: state.daily_tokens,
      monthly_tokens: state.monthly_tokens,
      daily_remaining: max(0.0, state.daily_limit - state.daily_spent),
      monthly_remaining: max(0.0, state.monthly_limit - state.monthly_spent),
      daily_reset_at: state.daily_reset_at,
      monthly_reset_at: state.monthly_reset_at,
      ledger_entries: length(state.entries)
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:record_cost, provider, model, tokens_in, tokens_out, session_id}, state) do
    cost = calculate_cost(provider, tokens_in, tokens_out)

    entry = %{
      provider: provider,
      model: model,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      cost: cost,
      session_id: session_id,
      recorded_at: DateTime.utc_now()
    }

    tokens = max(tokens_in, 0) + max(tokens_out, 0)

    state = %{
      state
      | daily_spent: state.daily_spent + cost,
        monthly_spent: state.monthly_spent + cost,
        daily_tokens: state.daily_tokens + tokens,
        monthly_tokens: state.monthly_tokens + tokens,
        # Keep at most 10 000 ledger entries in memory
        entries: Enum.take([entry | state.entries], 10_000)
    }

    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset_daily, state) do
    {:noreply,
     %{state | daily_spent: 0.0, daily_tokens: 0, daily_reset_at: tomorrow_midnight()}}
  end

  @impl true
  def handle_cast(:reset_monthly, state) do
    {:noreply,
     %{state | monthly_spent: 0.0, monthly_tokens: 0, monthly_reset_at: next_month_midnight()}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_reset(state) do
    now = DateTime.utc_now()
    state |> maybe_reset_daily(now) |> maybe_reset_monthly(now)
  end

  defp maybe_reset_daily(state, now) do
    if DateTime.compare(now, state.daily_reset_at) == :gt do
      %{state | daily_spent: 0.0, daily_tokens: 0, daily_reset_at: tomorrow_midnight()}
    else
      state
    end
  end

  defp maybe_reset_monthly(state, now) do
    if DateTime.compare(now, state.monthly_reset_at) == :gt do
      %{state | monthly_spent: 0.0, monthly_tokens: 0, monthly_reset_at: next_month_midnight()}
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
end
