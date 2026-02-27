defmodule OptimalSystemAgent.Agent.BudgetTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Budget

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_budget(opts \\ []) do
    defaults = [daily_limit: 10.0, monthly_limit: 100.0, per_call_limit: 2.0]
    merged = Keyword.merge(defaults, opts)

    # Start with a unique name to allow async tests
    name = :"budget_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Budget, merged, name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {pid, name}
  end

  defp record_cost(name, provider, model, tokens_in, tokens_out, session_id) do
    GenServer.cast(name, {:record_cost, provider, model, tokens_in, tokens_out, session_id})
    # Small sleep to ensure cast is processed
    Process.sleep(10)
  end

  defp check_budget(name) do
    GenServer.call(name, :check_budget)
  end

  defp get_status(name) do
    GenServer.call(name, :get_status)
  end

  defp reset_daily(name) do
    GenServer.cast(name, :reset_daily)
    Process.sleep(10)
  end

  # ---------------------------------------------------------------------------
  # record_cost
  # ---------------------------------------------------------------------------

  describe "record_cost/5" do
    test "updates daily_spent" do
      {_pid, name} = start_budget()

      # anthropic: input 3.0/1M, output 15.0/1M
      # 1000 input tokens = 0.003, 1000 output tokens = 0.015 => 0.018
      record_cost(name, :anthropic, "claude-sonnet-4-6", 1000, 1000, "session_1")

      {:ok, status} = get_status(name)
      assert status.daily_spent > 0.0
      assert status.monthly_spent > 0.0
      assert status.ledger_entries == 1
    end

    test "accumulates multiple cost entries" do
      {_pid, name} = start_budget()

      record_cost(name, :anthropic, "claude-sonnet-4-6", 1000, 1000, "session_1")
      record_cost(name, :openai, "gpt-4o", 2000, 500, "session_2")

      {:ok, status} = get_status(name)
      assert status.ledger_entries == 2
      assert status.daily_spent > 0.0
    end

    test "ollama costs nothing" do
      {_pid, name} = start_budget()

      record_cost(name, :ollama, "llama3", 100_000, 50_000, "session_1")

      {:ok, status} = get_status(name)
      assert status.daily_spent == 0.0
      assert status.monthly_spent == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # check_budget
  # ---------------------------------------------------------------------------

  describe "check_budget/0" do
    test "returns ok when under limit" do
      {_pid, name} = start_budget(daily_limit: 100.0, monthly_limit: 1000.0)

      record_cost(name, :anthropic, "claude-sonnet-4-6", 1000, 1000, "session_1")

      assert {:ok, %{daily_remaining: dr, monthly_remaining: mr}} = check_budget(name)
      assert dr > 0.0
      assert mr > 0.0
    end

    test "returns over_limit when daily exceeded" do
      {_pid, name} = start_budget(daily_limit: 0.001, monthly_limit: 1000.0)

      # This will exceed the tiny daily limit
      record_cost(name, :anthropic, "claude-sonnet-4-6", 10_000, 10_000, "session_1")

      assert {:over_limit, :daily} = check_budget(name)
    end

    test "returns over_limit when monthly exceeded" do
      {_pid, name} = start_budget(daily_limit: 1000.0, monthly_limit: 0.001)

      # This will exceed the tiny monthly limit
      record_cost(name, :anthropic, "claude-sonnet-4-6", 10_000, 10_000, "session_1")

      assert {:over_limit, :monthly} = check_budget(name)
    end
  end

  # ---------------------------------------------------------------------------
  # get_status
  # ---------------------------------------------------------------------------

  describe "get_status/0" do
    test "returns complete summary" do
      {_pid, name} = start_budget(daily_limit: 50.0, monthly_limit: 500.0, per_call_limit: 5.0)

      assert {:ok, status} = get_status(name)
      assert status.daily_limit == 50.0
      assert status.monthly_limit == 500.0
      assert status.per_call_limit == 5.0
      assert status.daily_spent == 0.0
      assert status.monthly_spent == 0.0
      assert status.daily_remaining == 50.0
      assert status.monthly_remaining == 500.0
      assert status.ledger_entries == 0
      assert %DateTime{} = status.daily_reset_at
      assert %DateTime{} = status.monthly_reset_at
    end
  end

  # ---------------------------------------------------------------------------
  # reset_daily
  # ---------------------------------------------------------------------------

  describe "reset_daily/0" do
    test "zeroes daily_spent" do
      {_pid, name} = start_budget()

      record_cost(name, :anthropic, "claude-sonnet-4-6", 10_000, 10_000, "session_1")

      {:ok, before_reset} = get_status(name)
      assert before_reset.daily_spent > 0.0

      reset_daily(name)

      {:ok, after_reset} = get_status(name)
      assert after_reset.daily_spent == 0.0
      # Monthly should not be reset
      assert after_reset.monthly_spent > 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # calculate_cost
  # ---------------------------------------------------------------------------

  describe "calculate_cost/3" do
    test "anthropic pricing" do
      # 1M input at $3.0 + 1M output at $15.0 = $18.0
      cost = Budget.calculate_cost(:anthropic, 1_000_000, 1_000_000)
      assert cost == 18.0
    end

    test "ollama is free" do
      cost = Budget.calculate_cost(:ollama, 1_000_000, 1_000_000)
      assert cost == 0.0
    end

    test "unknown provider uses default pricing" do
      # default: input 1.0/1M, output 3.0/1M
      cost = Budget.calculate_cost(:unknown_provider, 1_000_000, 1_000_000)
      assert cost == 4.0
    end
  end
end
