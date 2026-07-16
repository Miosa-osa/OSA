defmodule OptimalSystemAgent.Agent.PricingTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Pricing

  describe "rates/1" do
    test "prices the default GLM cloud model" do
      assert {0.60, 2.20} = Pricing.rates("glm-5.2:cloud")
    end

    test "matches known families by substring (case-insensitive)" do
      assert {3.0, 15.0} = Pricing.rates("claude-3-5-sonnet-20241022")
      assert {2.5, 10.0} = Pricing.rates("GPT-4o")
    end

    test "local ollama-hosted models are free" do
      assert Pricing.rates("ollama/llama3.1") == {0.0, 0.0}
      assert Pricing.rates("qwen2.5:7b") == {0.0, 0.0}
    end

    test "unknown model returns nil (never guessed)" do
      assert is_nil(Pricing.rates("totally-made-up-model-x"))
    end

    test "nil model returns nil" do
      assert is_nil(Pricing.rates(nil))
    end
  end

  describe "cost/2" do
    test "computes input + output cost per 1M tokens" do
      # 1M input @ $3, 1M output @ $15 => $18 for sonnet
      usage = %{input_tokens: 1_000_000, output_tokens: 1_000_000}
      assert Pricing.cost("claude-3-5-sonnet", usage) == 18.0
    end

    test "applies cache-write x1.25 and cache-read x0.1 multipliers off input rate" do
      # input rate $3/1M. 1M cache-write => 3 * 1.25 = 3.75. 1M cache-read => 3 * 0.1 = 0.3
      usage = %{
        input_tokens: 0,
        output_tokens: 0,
        cache_creation_input_tokens: 1_000_000,
        cache_read_input_tokens: 1_000_000
      }

      assert Pricing.cost("claude-3-5-sonnet", usage) == 4.05
    end

    test "unknown model costs $0.0" do
      usage = %{input_tokens: 5_000_000, output_tokens: 5_000_000}
      assert Pricing.cost("no-such-model", usage) == 0.0
    end

    test "tolerates string-keyed usage maps" do
      usage = %{"input_tokens" => 1_000_000, "output_tokens" => 0}
      assert Pricing.cost("glm-5.2:cloud", usage) == 0.60
    end
  end
end
