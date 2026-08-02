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

  # A turn's spend lives on the immutable state threaded through `ReactLoop`, so
  # an exception unwinding out of it takes the spend with it: `Loop`'s rescue arm
  # returns the PRE-turn state, and a turn that billed three round-trips before
  # crashing on the fourth used to record a flat 0 — dropping real money out of
  # session accounting AND out of the `max_budget_usd` cap. `record/2` therefore
  # mirrors its absolute counters into the process dictionary, which survives the
  # unwind because `ReactLoop.run/1` runs inline in the `Loop` GenServer process.
  describe "partial-spend surrender across a crashed turn" do
    setup do
      Accounting.forget_partial()
      on_exit(&Accounting.forget_partial/0)
      :ok
    end

    test "adopt_partial/1 recovers the spend of round-trips that completed before a crash" do
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      pre_turn = base_state()

      # Three billed round-trips, then the turn blows up and the state they
      # were accumulated onto becomes unreachable — exactly what an exception
      # inside ReactLoop does.
      assert_raise RuntimeError, fn ->
        pre_turn
        |> Accounting.record(usage)
        |> Accounting.record(usage)
        |> Accounting.record(usage)
        |> then(fn _lost -> raise "boom" end)
      end

      recovered = Accounting.adopt_partial(pre_turn)

      # 3 turns x $18 (sonnet 1M in @ $3 + 1M out @ $15).
      assert recovered.session_cost_usd == 54.0
      assert recovered.session_input_tokens == 3_000_000
      assert recovered.session_output_tokens == 3_000_000
      assert recovered.last_input_tokens == 1_000_000

      # Guard the actual defect: the pre-turn state on its own reports nothing,
      # which is what shipped.
      assert pre_turn.session_cost_usd == 0.0
      assert pre_turn.session_input_tokens == 0
    end

    test "adopting twice cannot double-bill" do
      # Absolute counters, not deltas, precisely so a duplicated or out-of-order
      # merge is idempotent.
      state = Accounting.record(base_state(), %{input_tokens: 1_000_000})

      once = Accounting.adopt_partial(base_state())
      twice = once |> Accounting.adopt_partial() |> Accounting.adopt_partial()

      assert once.session_cost_usd == state.session_cost_usd
      assert twice.session_cost_usd == once.session_cost_usd
      assert twice.session_input_tokens == once.session_input_tokens
    end

    test "adopt_partial/1 is a no-op when nothing was recorded" do
      state = base_state()
      assert Accounting.adopt_partial(state) == state
    end

    test "forget_partial/0 stops a later turn adopting an earlier turn's spend" do
      Accounting.record(base_state(), %{input_tokens: 1_000_000})

      # `Loop.run_and_reply/1` calls this at the top of every turn. The Loop
      # GenServer is long-lived, so without it a turn that crashes before its
      # first round-trip would inherit — and re-bill — the previous turn.
      Accounting.forget_partial()

      next_turn = base_state()
      assert Accounting.adopt_partial(next_turn) == next_turn
    end

    test "every counter record/2 writes is carried across the crash" do
      # A counter added to accounting but not to the stash list would be
      # silently dropped on a crashed turn — the exact class of bug this
      # mechanism exists to fix. Pin that the two stay in step.
      usage = %{
        input_tokens: 11,
        output_tokens: 22,
        cache_creation_input_tokens: 33,
        cache_read_input_tokens: 44
      }

      recorded = Accounting.record(base_state(), usage)
      recovered = Accounting.adopt_partial(base_state())

      for key <- [
            :session_cost_usd,
            :session_input_tokens,
            :session_output_tokens,
            :session_cache_creation_tokens,
            :session_cache_read_tokens,
            :last_input_tokens
          ] do
        assert Map.fetch!(recovered, key) == Map.fetch!(recorded, key),
               "#{key} was not carried across the crash boundary"
      end
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
