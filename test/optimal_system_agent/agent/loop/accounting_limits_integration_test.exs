defmodule OptimalSystemAgent.Agent.Loop.AccountingLimitsIntegrationTest do
  @moduledoc """
  End-to-end reliability: real token accounting (primitive #29) feeding the hard
  budget cap (`Loop.Limits`). Also covers the defensive guards that keep
  best-effort accounting from ever crashing a turn on a malformed loop state.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.Limits

  # A minimal loop-state map. glm-5.2:cloud → {0.60, 2.20} $/1M tokens.
  defp state(overrides \\ %{}) do
    Map.merge(
      %{session_id: "acct-int-#{System.unique_integer([:positive])}", model: "glm-5.2:cloud"},
      overrides
    )
  end

  defp usage(input, output),
    do: %{input_tokens: input, output_tokens: output}

  describe "accounting feeds the budget cap (primitive #29 end-to-end)" do
    test "spend accumulated by Accounting.record eventually trips the cap" do
      # cap at $0.01. Each round-trip: 1M input @ $0.60 = $0.60 — so ONE
      # round-trip already crosses a $0.01 cap.
      s = state(%{max_budget_usd: 0.01})

      refute Limits.budget_exceeded?(s)
      assert Limits.check(s) == nil

      s = Accounting.record(s, usage(1_000_000, 0))

      assert s.session_cost_usd > 0.01
      assert Limits.budget_exceeded?(s)
      assert Limits.check(s) =~ "Budget limit reached"
    end

    test "many small round-trips accumulate until the cap is crossed" do
      s = state(%{max_budget_usd: 0.05})

      # Each round-trip is 10k input tokens = $0.006. Need 9 to cross $0.05.
      s =
        Enum.reduce(1..9, s, fn _i, acc ->
          Accounting.record(acc, usage(10_000, 0))
        end)

      assert s.session_cost_usd >= 0.05
      assert Limits.budget_exceeded?(s)
    end

    test "no cap set never trips, regardless of spend (long runs are not killed)" do
      s = state()
      s = Accounting.record(s, usage(50_000_000, 50_000_000))

      assert s.session_cost_usd > 0
      refute Limits.budget_exceeded?(s)
      assert Limits.check(s) == nil
    end

    test "under-cap spend passes the limit check" do
      s = state(%{max_budget_usd: 100.0})
      s = Accounting.record(s, usage(1_000, 1_000))

      refute Limits.budget_exceeded?(s)
      assert Limits.check(s) == nil
    end
  end

  describe "accounting is a robust, additive state transform" do
    test "snapshot exposes the running spend and the cap" do
      s = state(%{max_budget_usd: 2.5})
      s = Accounting.record(s, usage(1_000_000, 1_000_000))

      snap = Accounting.snapshot(s)
      assert snap.input_tokens == 1_000_000
      assert snap.output_tokens == 1_000_000
      assert snap.cost_usd > 0
      assert snap.max_budget_usd == 2.5
    end

    test "cache tokens accumulate on their own counters" do
      s =
        state()
        |> Accounting.record(%{
          input_tokens: 0,
          output_tokens: 0,
          cache_creation_input_tokens: 5_000,
          cache_read_input_tokens: 7_000
        })

      assert s.session_cache_creation_tokens == 5_000
      assert s.session_cache_read_tokens == 7_000
    end
  end

  describe "defensive guards — record/2 never crashes the turn" do
    test "unknown model records tokens at $0 without raising" do
      s = state(%{model: "totally-unknown-model-zzz"})
      s = Accounting.record(s, usage(1_000, 2_000))

      assert s.session_input_tokens == 1_000
      assert s.session_output_tokens == 2_000
      assert s.session_cost_usd == 0.0
    end

    test "a non-string model (malformed state) degrades gracefully, no crash" do
      # model is an integer — Pricing.rates/1 previously had no matching clause.
      # The guard must return an updated state (or the input state) — never raise.
      s = state(%{model: 12_345})
      result = Accounting.record(s, usage(1_000, 1_000))

      assert is_map(result)
      assert Map.has_key?(result, :session_id)
    end

    test "nil usage is a no-op on cost" do
      s = state()
      s = Accounting.record(s, nil)
      assert s.session_cost_usd == 0.0
    end

    test "negative / garbage token values are clamped to 0" do
      s = state()
      s = Accounting.record(s, %{input_tokens: -50, output_tokens: "oops"})
      assert s.session_input_tokens == 0
      assert s.session_output_tokens == 0
    end
  end
end
