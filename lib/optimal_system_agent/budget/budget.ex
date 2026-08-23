defmodule OptimalSystemAgent.Budget do
  @moduledoc """
  Budget GenServer — token/cost tracking with daily and monthly limits.

  Tracks provider API spend across sessions. Budgets are opt-in: with no
  limit configured, spend is tracked but nothing is ever reported as over
  limit. When started from the supervisor, limits come from application env:

      config :optimal_system_agent,
        daily_budget_usd: 50.0,
        monthly_budget_usd: 200.0

  Leaving these unset (or nil) means no daily/monthly cap is enforced.

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

  # No default caps. A daily/monthly/per-call limit only applies once a user
  # (or config/env var) explicitly sets one; nil means "unlimited".
  @daily_default_usd nil
  @monthly_default_usd nil

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

  @doc """
  Record an API call cost, pricing it with this module's coarse per-PROVIDER
  rate table. Fire-and-forget.

  Prefer `record_priced_cost/5` when the caller already has a per-MODEL price —
  see its docs for why the two tables must not both bill the same tokens.
  """
  @spec record_cost(atom(), String.t(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def record_cost(provider, model, tokens_in, tokens_out, session_id) do
    GenServer.cast(__MODULE__, {:record_cost, provider, model, tokens_in, tokens_out, session_id})
  end

  @doc """
  Record an API call whose USD cost has ALREADY been computed by
  `OptimalSystemAgent.Agent.Pricing` — the per-model engine with real cache
  multipliers (`cache_read * input_rate * 0.1`, `cache_write * 1.25`).

  Two engines were billing the same tokens. `Loop.Accounting` priced each turn
  with `Pricing.cost/2`, then handed the SAME usage to `record_cost/5`, which
  re-priced it from the coarse provider table at the FULL input rate — and it
  was handed `effective_input_tokens` (input + cache-write + cache-read), so
  every cached token was billed as if it were fresh. On a cache-heavy session
  that inflates the daily/monthly figure `/cost` prints several-fold, in the
  direction that makes an operator think they are overspending.

  This entry point keeps `Pricing` the single billing engine: the ledger stores
  the number the session was actually charged. `record_cost/5` remains for
  callers (the SDK bridge, the usage hook) that have raw token counts and no
  priced value.
  """
  @spec record_priced_cost(atom(), String.t(), float(), non_neg_integer(), String.t()) :: :ok
  def record_priced_cost(provider, model, cost_usd, tokens, session_id) do
    GenServer.cast(
      __MODULE__,
      {:record_priced_cost, provider, model, cost_usd, tokens, session_id}
    )
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

  # ── Pause / resume (Tier 3 #12) ────────────────────────────────────────
  #
  # A security engagement can be paused (stop spending) and resumed. While
  # paused, `record_cost/5` and `record_priced_cost/5` accept the cast but
  # the cost is NOT accumulated — spending halts. `check_budget/0` and
  # `get_status/0` report `paused: true`. This lets an operator halt a
  # runaway engagement without killing the session, then resume when ready.

  @doc "Pause spending. Subsequent record_cost/record_priced_cost calls are dropped."
  @spec pause() :: :ok
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc "Resume spending after a pause."
  @spec resume() :: :ok
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc "Toggle pause state."
  @spec toggle_pause() :: :ok
  def toggle_pause do
    GenServer.call(__MODULE__, :toggle_pause)
  end

  @doc "True if spending is currently paused."
  @spec paused?() :: boolean()
  def paused? do
    GenServer.call(__MODULE__, :paused?)
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
      daily_calls: 0,
      monthly_calls: 0,
      # This ledger lives in memory only — see the `:counting_since` note on
      # `get_status/0`.
      counting_since: DateTime.utc_now(),
      daily_limit:
        Keyword.get(opts, :daily_limit) ||
          Application.get_env(:optimal_system_agent, :daily_budget_usd, @daily_default_usd),
      monthly_limit:
        Keyword.get(opts, :monthly_limit) ||
          Application.get_env(:optimal_system_agent, :monthly_budget_usd, @monthly_default_usd),
      per_call_limit: Keyword.get(opts, :per_call_limit),
      entries: [],
      daily_reset_at: tomorrow_midnight(),
      monthly_reset_at: next_month_midnight(),
      # Pause/resume (Tier 3 #12): when true, record_cost/record_priced_cost
      # are accepted but not accumulated. check_budget/get_status report it.
      paused: false
    }

    Logger.info(
      "[Budget] started, daily: #{limit_label(state.daily_limit)}, monthly: #{limit_label(state.monthly_limit)}"
    )

    {:ok, state}
  end

  def init(:ok), do: init([])

  @impl true
  def handle_call(:check_budget, _from, state) do
    state = maybe_reset(state)
    daily_remaining = remaining(state.daily_limit, state.daily_spent)
    monthly_remaining = remaining(state.monthly_limit, state.monthly_spent)

    result =
      cond do
        over_limit?(state.daily_limit, state.daily_spent) ->
          {:over_limit, :daily}

        over_limit?(state.monthly_limit, state.monthly_spent) ->
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
      daily_remaining: remaining(state.daily_limit, state.daily_spent),
      monthly_remaining: remaining(state.monthly_limit, state.monthly_spent),
      daily_reset_at: state.daily_reset_at,
      monthly_reset_at: state.monthly_reset_at,
      ledger_entries: length(state.entries),
      daily_calls: state.daily_calls,
      monthly_calls: state.monthly_calls,
      # Pause/resume (Tier 3 #12): true when spending is halted.
      paused: state.paused,
      # HONESTY FIELDS. Every counter above starts at zero in `init/1`: nothing
      # is loaded from disk and nothing is saved on `terminate/2`. So
      # `monthly_spent` is not the month's spend — it is the spend since this
      # OSA process started, which after a restart on the 28th is a few minutes
      # of data wearing a month's label. Consumers MUST render the period as
      # "since #{counting_since}" rather than "this month" while
      # `persisted: false`. The durable per-session record is the
      # `SessionPersistence` spend sidecar; this ledger is a live meter.
      persisted: false,
      counting_since: state.counting_since
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast({:record_cost, provider, model, tokens_in, tokens_out, session_id}, state) do
    # Reset BEFORE accumulating. Resets are lazy, and `:check_budget` /
    # `:get_status` were the only two callbacks that ran one — so spend recorded
    # between midnight and the first read landed in the previous day's bucket,
    # and the next read then zeroed that bucket wholesale. Real post-midnight
    # spend was erased and the day started with a false $0.
    state = maybe_reset(state)

    if state.paused do
      # Spending halted (Tier 3 #12): accept the cast, don't accumulate.
      {:noreply, state}
    else
      cost = calculate_cost(provider, tokens_in, tokens_out)
      tokens = max(tokens_in, 0) + max(tokens_out, 0)

      entry = %{
        provider: provider,
        model: model,
        tokens_in: tokens_in,
        tokens_out: tokens_out,
        cost: cost,
        session_id: session_id,
        recorded_at: DateTime.utc_now()
      }

      {:noreply, accumulate(state, cost, tokens, entry)}
    end
  end

  @impl true
  def handle_cast({:record_priced_cost, provider, model, cost_usd, tokens, session_id}, state) do
    state = maybe_reset(state)

    if state.paused do
      {:noreply, state}
    else
      cost = if is_number(cost_usd) and cost_usd > 0, do: cost_usd * 1.0, else: 0.0
      tokens = if is_integer(tokens) and tokens > 0, do: tokens, else: 0

      entry = %{
        provider: provider,
        model: model,
        tokens_in: nil,
        tokens_out: nil,
        cost: cost,
        session_id: session_id,
        recorded_at: DateTime.utc_now()
      }

      {:noreply, accumulate(state, cost, tokens, entry)}
    end
  end

  @impl true
  def handle_cast(:reset_daily, state) do
    {:noreply,
     %{
       state
       | daily_spent: 0.0,
         daily_tokens: 0,
         daily_calls: 0,
         daily_reset_at: tomorrow_midnight()
     }}
  end

  @impl true
  def handle_cast(:reset_monthly, state) do
    {:noreply,
     %{
       state
       | monthly_spent: 0.0,
         monthly_tokens: 0,
         monthly_calls: 0,
         monthly_reset_at: next_month_midnight()
     }}
  end

  # ── Pause / resume handlers (Tier 3 #12) ────────────────────────────────

  @impl true
  def handle_call(:pause, _from, state) do
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    {:reply, :ok, %{state | paused: false}}
  end

  @impl true
  def handle_call(:toggle_pause, _from, state) do
    {:reply, :ok, %{state | paused: not state.paused}}
  end

  @impl true
  def handle_call(:paused?, _from, state) do
    {:reply, state.paused, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp accumulate(state, cost, tokens, entry) do
    %{
      state
      | daily_spent: state.daily_spent + cost,
        monthly_spent: state.monthly_spent + cost,
        daily_tokens: state.daily_tokens + tokens,
        monthly_tokens: state.monthly_tokens + tokens,
        # Keep at most 10 000 ledger entries in memory
        entries: Enum.take([entry | state.entries], 10_000),
        # Call counts are their own counters, NOT `length(entries)`. `entries`
        # is a ring capped at 10 000, so the reported call count silently froze
        # at 10 000 and every call after that was invisible.
        daily_calls: state.daily_calls + 1,
        monthly_calls: state.monthly_calls + 1
    }
  end

  # A nil limit means "no budget configured": never over limit.
  defp over_limit?(limit, spent) when is_number(limit), do: spent >= limit
  defp over_limit?(_limit, _spent), do: false

  # A nil limit has no remaining amount to report.
  defp remaining(limit, spent) when is_number(limit), do: max(0.0, limit - spent)
  defp remaining(_limit, _spent), do: nil

  defp limit_label(limit) when is_number(limit), do: "$#{limit}"
  defp limit_label(_limit), do: "none"

  defp maybe_reset(state) do
    now = DateTime.utc_now()
    state |> maybe_reset_daily(now) |> maybe_reset_monthly(now)
  end

  defp maybe_reset_daily(state, now) do
    if DateTime.compare(now, state.daily_reset_at) == :gt do
      %{
        state
        | daily_spent: 0.0,
          daily_tokens: 0,
          daily_calls: 0,
          daily_reset_at: tomorrow_midnight()
      }
    else
      state
    end
  end

  defp maybe_reset_monthly(state, now) do
    if DateTime.compare(now, state.monthly_reset_at) == :gt do
      %{
        state
        | monthly_spent: 0.0,
          monthly_tokens: 0,
          monthly_calls: 0,
          monthly_reset_at: next_month_midnight()
      }
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
