defmodule OptimalSystemAgent.Providers.SurplusPricingTest do
  @moduledoc """
  Surplus is a margin-charging reseller, and `Agent.Pricing` is keyed by model
  id alone. Without a surplus-specific rate card every surplus turn either billed
  the upstream vendor's number at `:exact` (a shared id like `gpt-6-astra`
  matching OpenAI's native row) or billed $0.00 for an id no catalog carries
  (`kimi-k3`) — the latter blinding `max_budget_usd` to the spend entirely.

  These lock in the fix: `surplus/<id>` keys are priced from a RUNTIME card
  captured from the live catalog, with a conservative `:estimated` fallback that
  is never $0 and never a native vendor's `:exact` row.

  `async: false` — the runtime card lives in `:persistent_term`, which is global.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Providers.SurplusModels

  # A turn of pure input/output tokens, so cost is a direct function of the rate.
  @usage %{input_tokens: 1_000_000, output_tokens: 1_000_000}

  setup do
    SurplusModels.reset_runtime_pricing()
    on_exit(&SurplusModels.reset_runtime_pricing/0)
    :ok
  end

  describe "qualify/2 namespaces surplus ids" do
    test "a bare surplus id becomes a surplus/ key" do
      assert Pricing.qualify("kimi-k3", :surplus) == "surplus/kimi-k3"
      assert Pricing.qualify("gpt-6-astra", :surplus) == "surplus/gpt-6-astra"
    end

    test "surplus is a registered reseller prefix" do
      assert Pricing.reseller_prefixes()[:surplus] == "surplus/"
    end

    test "identity for a non-reseller provider" do
      assert Pricing.qualify("kimi-k3", :openai) == "kimi-k3"
      assert Pricing.qualify(nil, :surplus) == nil
    end
  end

  describe "empty runtime card — the budget-enforcement guarantee" do
    test "kimi-k3 prices NON-ZERO as :estimated, not $0" do
      key = Pricing.qualify("kimi-k3", :surplus)

      # The whole point: an un-fetched catalog must not bill $0 and blind the cap.
      assert Pricing.rates(key) == {2.0, 10.0}
      assert Pricing.confidence(key) == :estimated
      assert Pricing.cost(key, @usage) > 0.0
    end

    test "the fallback is not a native vendor's :exact rate for a shared id" do
      key = Pricing.qualify("gpt-6-astra", :surplus)

      # OpenAI's native gpt-4-family/`gpt-6` path must not answer here.
      assert Pricing.confidence(key) == :estimated
      refute Pricing.rates(key) == {10.0, 50.0}
      assert Pricing.rates(key) == {2.0, 10.0}
    end
  end

  describe "populated runtime card — the gateway's own published price" do
    test "a stubbed surplus/kimi-k3 row is returned, :exact" do
      SurplusModels.put_runtime_pricing([
        SurplusModels.parse(%{
          "id" => "kimi-k3",
          "pricing" => %{"prompt" => "0.0000036", "completion" => "0.000018"}
        })
      ])

      key = Pricing.qualify("kimi-k3", :surplus)

      assert Pricing.rates(key) == {3.6, 18.0}
      assert Pricing.confidence(key) == :exact
      # 1M in @ 3.6 + 1M out @ 18.0 = 21.6 / 1M-per-token unit.
      assert Pricing.cost(key, @usage) == 21.6
    end

    test "a shared id under surplus bills surplus' price, not the native vendor's" do
      SurplusModels.put_runtime_pricing([
        SurplusModels.parse(%{
          "id" => "gpt-6-astra",
          "pricing" => %{"prompt" => "0.000012", "completion" => "0.00006"}
        })
      ])

      key = Pricing.qualify("gpt-6-astra", :surplus)

      assert Pricing.rates(key) == {12.0, 60.0}
      assert Pricing.confidence(key) == :exact
      refute Pricing.rates(key) == {10.0, 50.0}
    end

    test "an id absent from the fetched card AND the static card falls to the safe estimate" do
      SurplusModels.put_runtime_pricing([
        SurplusModels.parse(%{
          "id" => "kimi-k3",
          "pricing" => %{"prompt" => "0.0000036", "completion" => "0.000018"}
        })
      ])

      # grok-4.6 is featured but non-Claude, so it has no static rate card entry
      # and is not in this runtime card — it must still price non-zero.
      key = Pricing.qualify("grok-4.6", :surplus)

      assert Pricing.rates(key) == {2.0, 10.0}
      assert Pricing.confidence(key) == :estimated
      assert Pricing.cost(key, @usage) > 0.0
    end

    test "a zero-priced catalog row is dropped, not billed as a real $0 rate" do
      SurplusModels.put_runtime_pricing([
        SurplusModels.parse(%{
          "id" => "kimi-k3",
          "pricing" => %{"prompt" => "0", "completion" => "0"}
        })
      ])

      key = Pricing.qualify("kimi-k3", :surplus)

      # No usable price captured → conservative estimate, not $0.
      assert Pricing.rates(key) == {2.0, 10.0}
      assert Pricing.confidence(key) == :estimated
    end
  end

  describe "no regression on the uncensored reseller" do
    test "uncensored still prices from its static card at :exact" do
      # claude-opus-5 on the gateway is {6.00, 30.00}; the native Anthropic row
      # is {5.00, 25.00}. The namespaced key must reach the gateway's number.
      key = Pricing.qualify("claude-opus-5", :uncensored)

      assert key == "uncensored/claude-opus-5"
      assert Pricing.rates(key) == {6.0, 30.0}
      assert Pricing.confidence(key) == :exact
    end

    test "the bare vendor id is untouched by adding the surplus prefix" do
      assert Pricing.rates("claude-opus-5") == {5.0, 25.0}
      assert Pricing.confidence("claude-opus-5") == :exact
    end
  end
end
