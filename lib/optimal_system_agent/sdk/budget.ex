defmodule OptimalSystemAgent.SDK.Budget do
  @moduledoc """
  SDK wrapper for the Agent.Budget subsystem.

  Provides token/cost tracking, budget enforcement, and spend visibility.
  """

  alias OptimalSystemAgent.Agent.Budget

  @doc """
  Check if current spending is within budget limits.

  Returns `{:ok, %{daily_remaining: float, monthly_remaining: float}}`
  or `{:over_limit, :daily | :monthly}`.
  """
  @spec check() :: {:ok, map()} | {:over_limit, :daily | :monthly}
  def check do
    Budget.check_budget()
  end

  @doc """
  Get full budget status: limits, spent, remaining, reset times.
  """
  @spec status() :: {:ok, map()}
  def status do
    Budget.get_status()
  end

  @doc """
  Record an API cost entry.

  Called automatically by the cost_tracker hook, but available for
  manual recording from SDK consumers.
  """
  @spec record_cost(String.t(), String.t(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def record_cost(provider, model, tokens_in, tokens_out, session_id) do
    Budget.record_cost(provider, model, tokens_in, tokens_out, session_id)
  end

  @doc """
  Calculate USD cost for a given token count (pure function, no side effects).
  """
  @spec calculate_cost(String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def calculate_cost(provider, tokens_in, tokens_out) do
    Budget.calculate_cost(provider, tokens_in, tokens_out)
  end

  @doc "Reset daily spend counter."
  @spec reset_daily() :: :ok
  def reset_daily, do: Budget.reset_daily()

  @doc "Reset monthly spend counter."
  @spec reset_monthly() :: :ok
  def reset_monthly, do: Budget.reset_monthly()

  @doc """
  Set daily budget limit in USD.

  Writes to Application env. Takes effect on next Budget GenServer restart
  or when using SDK.Supervisor (which sets env before Budget starts).
  """
  @spec set_daily_limit(float()) :: :ok
  def set_daily_limit(usd) when is_number(usd) and usd > 0 do
    Application.put_env(:optimal_system_agent, :daily_budget_usd, usd)
    :ok
  end

  @doc """
  Set monthly budget limit in USD.

  Writes to Application env. Takes effect on next Budget GenServer restart.
  """
  @spec set_monthly_limit(float()) :: :ok
  def set_monthly_limit(usd) when is_number(usd) and usd > 0 do
    Application.put_env(:optimal_system_agent, :monthly_budget_usd, usd)
    :ok
  end
end
