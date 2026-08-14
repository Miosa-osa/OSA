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

  # ── Provider prompt-slice conventions (the cache-rate misapplication) ────
  #
  # Anthropic reports input/cache_write/cache_read as DISJOINT slices; every
  # OpenAI-shaped API reports `input_tokens` INCLUSIVE of `cached_tokens`.
  # Pricing.cost/2 assumes disjoint, so an unreconciled inclusive map bills the
  # cached portion at `1.0 + 0.1` of the input rate — 11x the real cache-read
  # price — and effective_input_tokens/1 counts the cached prompt twice.
  #
  # The live cache-read count is 0 today, which is exactly why this is pinned
  # now: the path goes live the moment prompt caching starts hitting, and a
  # regression here would be invisible until the next provider invoice.
  describe "reconcile_prompt_slices/2" do
    test "an OpenAI-shaped inclusive map has the cached portion removed from input" do
      norm =
        Accounting.normalize_usage(%{
          input_tokens: 100_000,
          output_tokens: 1_000,
          cache_read_input_tokens: 90_000
        })

      assert %{input_tokens: 10_000, cache_read_input_tokens: 90_000} =
               Accounting.reconcile_prompt_slices(norm, :openrouter)
    end

    test "an Anthropic disjoint map is left exactly as reported" do
      norm =
        Accounting.normalize_usage(%{
          input_tokens: 10_000,
          output_tokens: 1_000,
          cache_read_input_tokens: 90_000
        })

      assert Accounting.reconcile_prompt_slices(norm, :anthropic) == norm
    end

    test "an unknown provider is left alone rather than guessed in either direction" do
      norm = Accounting.normalize_usage(%{input_tokens: 100, cache_read_input_tokens: 40})
      assert Accounting.reconcile_prompt_slices(norm, nil) == norm
      assert Accounting.reconcile_prompt_slices(norm, :some_new_provider) == norm
    end

    test "a {:compat, _} dispatch target is inclusive" do
      norm = Accounting.normalize_usage(%{input_tokens: 100, cache_read_input_tokens: 40})

      assert %{input_tokens: 60} =
               Accounting.reconcile_prompt_slices(norm, {:compat, :openrouter})
    end

    test "reconciliation never drives input negative" do
      norm = Accounting.normalize_usage(%{input_tokens: 10, cache_read_input_tokens: 999})
      assert %{input_tokens: 0} = Accounting.reconcile_prompt_slices(norm, :openai)
    end

    test "reconciliation is NOT idempotent, so it must stay on exactly one path" do
      # Stated rather than wished away: subtracting the cached portion twice
      # under-bills. `record/2` is the single call site, applied to a freshly
      # normalized provider map, and this pins the shape a second application
      # would produce so that anyone adding a second call site sees why not.
      norm = Accounting.normalize_usage(%{input_tokens: 100_000, cache_read_input_tokens: 90_000})
      once = Accounting.reconcile_prompt_slices(norm, :openrouter)
      twice = Accounting.reconcile_prompt_slices(once, :openrouter)

      assert once.input_tokens == 10_000
      assert twice.input_tokens == 0
      refute twice == once
    end

    test "record/2 reconciles exactly once — the second call is a fresh round-trip" do
      state = %{base_state() | provider: :openrouter, model: "anthropic/claude-opus-5"}
      usage = %{input_tokens: 100_000, cache_read_input_tokens: 90_000}

      one = Accounting.record(state, usage)
      two = Accounting.record(one, usage)

      # Two identical round-trips cost exactly twice one, not less.
      assert_in_delta two.session_cost_usd, one.session_cost_usd * 2, 0.000_01
      assert two.session_input_tokens == one.session_input_tokens * 2
    end

    test "record/2 bills a cache read at 0.1x, not 1.1x, on an OpenAI-shaped provider" do
      state = %{
        base_state()
        | model: "anthropic/claude-opus-5",
          provider: :openrouter
      }

      # 1M prompt tokens of which 900k were cache hits, reported inclusively.
      usage = %{
        input_tokens: 1_000_000,
        output_tokens: 0,
        cache_read_input_tokens: 900_000
      }

      recorded = Accounting.record(state, usage)

      # 100k fresh @ $5/1M + 900k cached @ $0.50/1M = 0.50 + 0.45
      assert_in_delta recorded.session_cost_usd, 0.95, 0.000_01

      # The unreconciled figure would have been 1M @ $5 + 900k @ $0.50 = $5.45.
      refute_in_delta recorded.session_cost_usd, 5.45, 0.01
    end

    test "context pressure no longer counts the cached prompt twice" do
      state = %{base_state() | provider: :openrouter, model: "anthropic/claude-opus-5"}

      recorded =
        Accounting.record(state, %{input_tokens: 1_000_000, cache_read_input_tokens: 900_000})

      # The prompt occupied 1M tokens of context, not 1.9M.
      assert recorded.last_input_tokens == 1_000_000
    end
  end

  # ── Double counting ─────────────────────────────────────────────────────
  describe "no double counting" do
    test "one round-trip is billed exactly once" do
      state = %{base_state() | model: "anthropic/claude-opus-5", provider: :openrouter}
      usage = %{input_tokens: 1_534_954, output_tokens: 9_929}

      once = Accounting.record(state, usage)
      # This is the or-opus5-probe3 instance, reconciled against the provider.
      assert_in_delta once.session_cost_usd, 7.923, 0.001
      assert once.session_input_tokens == 1_534_954
    end

    test "the crash-recovery stash is an ABSOLUTE snapshot, so re-adopting cannot re-bill" do
      state = %{base_state() | model: "anthropic/claude-opus-5", provider: :openrouter}
      recorded = Accounting.record(state, %{input_tokens: 1_000_000, output_tokens: 0})

      twice = recorded |> Accounting.adopt_partial() |> Accounting.adopt_partial()

      assert twice.session_cost_usd == recorded.session_cost_usd
      assert twice.session_input_tokens == recorded.session_input_tokens
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
