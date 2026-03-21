defmodule OptimalSystemAgent.Agent.Budget do
  @moduledoc """
  API cost tracking and budget enforcement.

  Tracks daily, monthly, and per-call spending against configurable limits.
  Maintains an in-memory ledger of all cost entries and schedules automatic
  daily/monthly resets via Process.send_after.

  Limits default to environment variables or application config:
  - OSA_DAILY_BUDGET_USD (default 50.0)
  - OSA_MONTHLY_BUDGET_USD (default 500.0)
  - OSA_PER_CALL_LIMIT_USD (default 5.0)

  Events emitted on :system_event:
  - :budget_warning — when spend exceeds 80% of daily or monthly limit
  - :budget_exceeded — when a limit is hit
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  # ── Token Pricing (per 1M tokens, USD) ──────────────────────────────

  @pricing %{
    anthropic: %{input: 3.0, output: 15.0},
    openai: %{input: 5.0, output: 15.0},
    groq: %{input: 0.27, output: 0.27},
    ollama: %{input: 0.0, output: 0.0},
    openrouter: %{input: 2.0, output: 6.0},
    default: %{input: 1.0, output: 3.0}
  }

  # ── State ────────────────────────────────────────────────────────────

  defstruct daily_limit: 50.0,
            monthly_limit: 500.0,
            per_call_limit: 5.0,
            daily_spent: 0.0,
            monthly_spent: 0.0,
            daily_reset_at: nil,
            monthly_reset_at: nil,
            ledger: []

  @daily_reset_ms 24 * 60 * 60 * 1000
  @monthly_reset_ms 30 * 24 * 60 * 60 * 1000

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a cost entry for an API call.
  Calculates cost from token counts and the provider's pricing table.
  """
  def record_cost(provider, model, tokens_in, tokens_out, session_id) do
    GenServer.cast(__MODULE__, {:record_cost, provider, model, tokens_in, tokens_out, session_id})
  end

  @doc """
  Check current budget status.
  Returns `{:ok, %{daily_remaining: x, monthly_remaining: y}}` or
  `{:over_limit, :daily | :monthly}`.
  """
  def check_budget do
    GenServer.call(__MODULE__, :check_budget)
  end

  @doc "Get full spend summary including limits, spent, and ledger size."
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc "Manually reset daily spend counter."
  def reset_daily do
    GenServer.cast(__MODULE__, :reset_daily)
  end

  @doc "Manually reset monthly spend counter."
  def reset_monthly do
    GenServer.cast(__MODULE__, :reset_monthly)
  end

  @doc "Calculate USD cost for a given provider and token counts."
  def calculate_cost(provider, tokens_in, tokens_out) do
    rates = Map.get(@pricing, normalize_provider(provider), @pricing.default)
    input_cost = tokens_in / 1_000_000 * rates.input
    output_cost = tokens_out / 1_000_000 * rates.output
    Float.round(input_cost + output_cost, 6)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    daily_limit =
      parse_float_env(
        "OSA_DAILY_BUDGET_USD",
        Keyword.get(
          opts,
          :daily_limit,
          Application.get_env(:optimal_system_agent, :daily_budget_usd, 50.0)
        )
      )

    monthly_limit =
      parse_float_env(
        "OSA_MONTHLY_BUDGET_USD",
        Keyword.get(
          opts,
          :monthly_limit,
          Application.get_env(:optimal_system_agent, :monthly_budget_usd, 500.0)
        )
      )

    per_call_limit =
      parse_float_env(
        "OSA_PER_CALL_LIMIT_USD",
        Keyword.get(
          opts,
          :per_call_limit,
          Application.get_env(:optimal_system_agent, :per_call_limit_usd, 5.0)
        )
      )

    now = DateTime.utc_now()

    state = %__MODULE__{
      daily_limit: daily_limit,
      monthly_limit: monthly_limit,
      per_call_limit: per_call_limit,
      daily_reset_at: DateTime.add(now, @daily_reset_ms, :millisecond),
      monthly_reset_at: DateTime.add(now, @monthly_reset_ms, :millisecond)
    }

    schedule_daily_reset()
    schedule_monthly_reset()

    Logger.info(
      "[Agent.Budget] Started — daily: $#{daily_limit}, monthly: $#{monthly_limit}, per-call: $#{per_call_limit}"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_cost, provider, model, tokens_in, tokens_out, session_id}, state) do
    cost = calculate_cost(provider, tokens_in, tokens_out)

    entry = %{
      id: "budget_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)),
      timestamp: DateTime.utc_now(),
      provider: to_string(provider),
      model: to_string(model),
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      cost_usd: cost,
      session_id: session_id
    }

    new_daily = state.daily_spent + cost
    new_monthly = state.monthly_spent + cost

    state = %{
      state
      | daily_spent: new_daily,
        monthly_spent: new_monthly,
        ledger: Enum.take([entry | state.ledger], 10_000)
    }

    # Emit warnings at 80% thresholds
    if new_daily > state.daily_limit * 0.8 and new_daily - cost <= state.daily_limit * 0.8 do
      Bus.emit(:system_event, %{
        event: :budget_warning,
        type: :daily,
        spent: new_daily,
        limit: state.daily_limit,
        utilization: new_daily / state.daily_limit,
        message: "Daily spend at #{round(new_daily / state.daily_limit * 100)}% ($#{Float.round(new_daily, 2)} / $#{state.daily_limit})",
        session_id: session_id
      })
    end

    if new_monthly > state.monthly_limit * 0.8 and new_monthly - cost <= state.monthly_limit * 0.8 do
      Bus.emit(:system_event, %{
        event: :budget_warning,
        type: :monthly,
        spent: new_monthly,
        limit: state.monthly_limit,
        utilization: new_monthly / state.monthly_limit,
        message: "Monthly spend at #{round(new_monthly / state.monthly_limit * 100)}% ($#{Float.round(new_monthly, 2)} / $#{state.monthly_limit})",
        session_id: session_id
      })
    end

    # Emit exceeded events
    if new_daily > state.daily_limit do
      Bus.emit(:system_event, %{
        event: :budget_exceeded,
        type: :daily,
        spent: new_daily,
        limit: state.daily_limit,
        message: "Daily budget exceeded: $#{Float.round(new_daily, 2)} / $#{state.daily_limit}",
        session_id: session_id
      })

      Logger.warning(
        "[Agent.Budget] Daily budget exceeded: $#{Float.round(new_daily, 2)} / $#{state.daily_limit}"
      )
    end

    if new_monthly > state.monthly_limit do
      Bus.emit(:system_event, %{
        event: :budget_exceeded,
        type: :monthly,
        spent: new_monthly,
        limit: state.monthly_limit,
        message: "Monthly budget exceeded: $#{Float.round(new_monthly, 2)} / $#{state.monthly_limit}",
        session_id: session_id
      })

      Logger.warning(
        "[Agent.Budget] Monthly budget exceeded: $#{Float.round(new_monthly, 2)} / $#{state.monthly_limit}"
      )
    end

    Logger.debug(
      "[Agent.Budget] Recorded $#{Float.round(cost, 4)} (#{provider}/#{model}) — " <>
        "daily: $#{Float.round(new_daily, 2)}, monthly: $#{Float.round(new_monthly, 2)}"
    )

    # Bridge to Treasury — emit cost event for auto-debit
    Bus.emit(:system_event, %{
      event: :cost_recorded,
      cost_usd: cost,
      provider: to_string(provider),
      model: to_string(model),
      session_id: session_id,
      entry_id: entry.id
    })

    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset_daily, state) do
    Logger.info("[Agent.Budget] Daily spend reset (was $#{Float.round(state.daily_spent, 2)})")

    state = %{
      state
      | daily_spent: 0.0,
        daily_reset_at: DateTime.add(DateTime.utc_now(), @daily_reset_ms, :millisecond)
    }

    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset_monthly, state) do
    Logger.info(
      "[Agent.Budget] Monthly spend reset (was $#{Float.round(state.monthly_spent, 2)})"
    )

    state = %{
      state
      | monthly_spent: 0.0,
        monthly_reset_at: DateTime.add(DateTime.utc_now(), @monthly_reset_ms, :millisecond)
    }

    {:noreply, state}
  end

  @impl true
  def handle_call(:check_budget, _from, state) do
    result =
      cond do
        state.daily_spent >= state.daily_limit ->
          {:over_limit, :daily}

        state.monthly_spent >= state.monthly_limit ->
          {:over_limit, :monthly}

        true ->
          {:ok,
           %{
             daily_remaining: Float.round(state.daily_limit - state.daily_spent, 2),
             monthly_remaining: Float.round(state.monthly_limit - state.monthly_spent, 2)
           }}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      daily_limit: state.daily_limit,
      monthly_limit: state.monthly_limit,
      per_call_limit: state.per_call_limit,
      daily_spent: Float.round(state.daily_spent, 4),
      monthly_spent: Float.round(state.monthly_spent, 4),
      daily_remaining: Float.round(state.daily_limit - state.daily_spent, 2),
      monthly_remaining: Float.round(state.monthly_limit - state.monthly_spent, 2),
      daily_reset_at: state.daily_reset_at,
      monthly_reset_at: state.monthly_reset_at,
      ledger_entries: length(state.ledger)
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info(:reset_daily, state) do
    Logger.info(
      "[Agent.Budget] Scheduled daily reset (was $#{Float.round(state.daily_spent, 2)})"
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
      "[Agent.Budget] Scheduled monthly reset (was $#{Float.round(state.monthly_spent, 2)})"
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

  defp schedule_daily_reset do
    Process.send_after(self(), :reset_daily, @daily_reset_ms)
  end

  defp schedule_monthly_reset do
    Process.send_after(self(), :reset_monthly, @monthly_reset_ms)
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider

  defp normalize_provider(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> :default
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
