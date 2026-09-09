defmodule OptimalSystemAgent.Providers.SurplusClaude5Test do
  @moduledoc """
  Pins the Claude 5 family on the Surplus provider (v1.0.185): each id is
  featured (offered in the picker), prices at its real Surplus reseller rate as
  `:exact` (never the {2,10} provider-level estimate), resolves to its 1M
  context window (never the 128k default), and cache-enables through the
  capability-keyed gate — all handled by the existing machinery with no per-id
  wiring beyond the static rate card.

  `async: false` — the runtime rate card lives in `:persistent_term` (global).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.{Registry, SurplusModels}
  alias OptimalSystemAgent.Agent.Pricing

  # {id, {input, output}} — Surplus's published reseller rates, all 1M context.
  @claude5 [
    {"claude-fable-5.1", {2.50, 12.50}},
    {"claude-fable-5", {5.75, 28.75}},
    {"claude-opus-5", {0.092, 0.46}},
    {"claude-opus-5-fast", {3.00, 15.00}},
    {"claude-sonnet-5", {0.50, 2.49}}
  ]

  setup do
    # Static-card path is the offline default; clear any leaked runtime card so
    # these assertions exercise the shipped static rates deterministically.
    SurplusModels.reset_runtime_pricing()
    on_exit(&SurplusModels.reset_runtime_pricing/0)
    :ok
  end

  test "every Claude 5 model is featured (offered in the picker)" do
    for {id, _} <- @claude5 do
      assert SurplusModels.featured?(id), "#{id} is not in the Surplus featured shortlist"
      assert id in SurplusModels.ids()
    end
  end

  test "each prices at its real Surplus rate, reported :exact — never the {2,10} estimate" do
    for {id, want} <- @claude5 do
      key = Pricing.qualify(id, :surplus)
      assert key == "surplus/" <> id

      assert Pricing.rates(key) == want,
             "#{id} priced #{inspect(Pricing.rates(key))}, want #{inspect(want)}"

      assert Pricing.confidence(key) == :exact
      refute Pricing.rates(key) == {2.0, 10.0}
    end
  end

  test "each resolves to a 1M context window, not the 128k default" do
    for {id, _} <- @claude5 do
      assert Registry.context_window(id) == 1_000_000,
             "#{id} resolved to #{Registry.context_window(id)}, not 1M"
    end
  end

  test "each cache-enables through the capability-keyed gate (tuple and bare atom)" do
    for {id, _} <- @claude5 do
      assert Registry.anthropic_prompt_cache?({:compat, :surplus}, id)
      assert Registry.anthropic_prompt_cache?(:surplus, id)
    end
  end

  test "the live runtime catalog overrides the static rate (no misprice when fetched)" do
    SurplusModels.put_runtime_pricing([
      SurplusModels.parse(%{
        "id" => "claude-opus-5",
        "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000005"}
      })
    ])

    key = Pricing.qualify("claude-opus-5", :surplus)

    assert Pricing.rates(key) == {0.1, 0.5},
           "live catalog price must win over the static snapshot"

    assert Pricing.confidence(key) == :exact
  end

  test "static_rate/1 is nil for a non-featured id (falls to the runtime/estimate path)" do
    assert SurplusModels.static_rate("surplus/kimi-k3") == nil
    # And with an empty runtime card, kimi-k3 still prices non-zero (budget-safe).
    key = Pricing.qualify("kimi-k3", :surplus)
    assert Pricing.rates(key) == {2.0, 10.0}
    assert Pricing.confidence(key) == :estimated
  end
end
