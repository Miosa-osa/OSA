defmodule OptimalSystemAgent.Agent.Loop.AccountingTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.Accounting

  # Accounting.record/2 bridges real usage into the *global* Budget ledger
  # (see Accounting.maybe_bridge_budget/2). These tests deliberately record
  # large token counts, which would leak accumulated spend into the global
  # Budget and trip the spend_guard hook in unrelated tests under random
  # ordering. Zero the global daily/monthly ledger after each test (the ledger
  # starts at 0 at boot and nothing asserts its accumulated value, so this is a
  # faithful restore). The synchronous get_status/0 call flushes the reset casts.
  setup do
    on_exit(fn ->
      if Process.whereis(OptimalSystemAgent.Budget) do
        OptimalSystemAgent.Budget.reset_daily()
        OptimalSystemAgent.Budget.reset_monthly()
        OptimalSystemAgent.Budget.get_status()
      end
    end)

    :ok
  end

  defp base_state do
    %{
      session_id: "acct-test-#{System.unique_integer([:positive])}",
      model: "claude-3-5-sonnet",
      provider: :anthropic,
      last_input_tokens: 0,
      session_cost_usd: 0.0,
      session_input_tokens: 0,
      session_output_tokens: 0,
      session_cache_creation_tokens: 0,
      session_cache_read_tokens: 0,
      max_budget_usd: nil
    }
  end

  describe "normalize_usage/1" do
    test "fills all four token kinds and tolerates nil" do
      assert %{
               input_tokens: 0,
               output_tokens: 0,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 0
             } = Accounting.normalize_usage(nil)
    end

    test "reads atom and string keys" do
      assert %{input_tokens: 10, output_tokens: 5} =
               Accounting.normalize_usage(%{"input_tokens" => 10, output_tokens: 5})
    end

    test "clamps negative / non-integer values to 0" do
      assert %{input_tokens: 0} = Accounting.normalize_usage(%{input_tokens: -3})
    end
  end

  describe "record/2" do
    test "accumulates cost and per-kind tokens across turns" do
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}

      state =
        base_state()
        |> Accounting.record(usage)
        |> Accounting.record(usage)

      # 2 turns x $18 (sonnet 1M in @ $3 + 1M out @ $15)
      assert state.session_cost_usd == 36.0
      assert state.session_input_tokens == 2_000_000
      assert state.session_output_tokens == 2_000_000
      assert state.last_input_tokens == 1_000_000
    end

    test "accumulates cache tokens separately" do
      usage = %{
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 100,
        cache_read_input_tokens: 200
      }

      state = Accounting.record(base_state(), usage)
      assert state.session_cache_creation_tokens == 100
      assert state.session_cache_read_tokens == 200
    end

    test "unknown model records tokens but $0 cost" do
      state =
        %{base_state() | model: "mystery-model"}
        |> Accounting.record(%{input_tokens: 500_000, output_tokens: 500_000})

      assert state.session_cost_usd == 0.0
      assert state.session_input_tokens == 500_000
    end

    test "empty usage is a no-op on cost" do
      state = Accounting.record(base_state(), %{})
      assert state.session_cost_usd == 0.0
    end
  end

  describe "snapshot/1" do
    test "exposes running spend for the TUI / auto-mode" do
      state = Accounting.record(base_state(), %{input_tokens: 1_000_000, output_tokens: 0})
      snap = Accounting.snapshot(state)
      assert snap.cost_usd == 3.0
      assert snap.input_tokens == 1_000_000
      assert Map.has_key?(snap, :max_budget_usd)
    end
  end
end
