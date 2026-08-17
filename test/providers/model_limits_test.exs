defmodule OptimalSystemAgent.Providers.ModelLimitsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ModelLimits

  describe "max_output/1" do
    test "reads the catalog output limit for a known model" do
      # Sonnet 4.6's published max output is 128k. The bundled models.dev
      # snapshot says 64k, and it used to win — halving the ceiling of every
      # response. Providers.AnthropicModels is now consulted first.
      assert ModelLimits.max_output("claude-sonnet-4-6") == 128_000
      assert ModelLimits.max_output("gpt-4o") == 16_384
    end

    test "the vendor catalog modules win over the bundled models.dev snapshot" do
      assert ModelLimits.max_output("claude-opus-5") == 128_000
      assert ModelLimits.max_output("claude-haiku-4-5") == 64_000
      assert ModelLimits.max_output("gpt-5.6-terra") == 128_000
    end

    test "returns nil for an unknown model with no static fallback" do
      assert ModelLimits.max_output("no-such-model-xyz") == nil
    end

    test "returns nil for nil / non-binary" do
      assert ModelLimits.max_output(nil) == nil
    end
  end

  describe "tool_call/2 and reasoning/2" do
    test "returns the catalog tool_call flag when present" do
      assert ModelLimits.tool_call(:openai, "gpt-4o") == true
    end

    test "returns the catalog reasoning flag when present" do
      assert ModelLimits.reasoning(:openai, "gpt-4o") == false
      assert ModelLimits.reasoning(:openai, "o3") == true
    end

    test "resolves OpenRouter vendor-prefixed model ids through native catalog metadata" do
      assert ModelLimits.tool_call(:openrouter, "anthropic/claude-sonnet-4-6") == true
      assert ModelLimits.reasoning(:openrouter, "openai/o3") == true
    end

    test "returns nil when the catalog has no entry (caller uses its own heuristic)" do
      assert ModelLimits.tool_call(:ollama, "unknown-local-model-xyz") == nil
      assert ModelLimits.reasoning(:ollama, "unknown-local-model-xyz") == nil
    end
  end
end
