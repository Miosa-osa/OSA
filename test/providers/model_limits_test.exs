defmodule OptimalSystemAgent.Providers.ModelLimitsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ModelLimits

  describe "max_output/1" do
    test "reads the catalog output limit for a known model" do
      assert ModelLimits.max_output("claude-sonnet-4-6") == 64_000
      assert ModelLimits.max_output("gpt-4o") == 16_384
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

    test "returns nil when the catalog has no entry (caller uses its own heuristic)" do
      assert ModelLimits.tool_call(:ollama, "unknown-local-model-xyz") == nil
      assert ModelLimits.reasoning(:ollama, "unknown-local-model-xyz") == nil
    end
  end
end
