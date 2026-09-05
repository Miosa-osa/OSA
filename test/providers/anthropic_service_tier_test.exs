defmodule OptimalSystemAgent.Providers.AnthropicServiceTierTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Anthropic

  test "encodes the safe automatic priority-capacity tier" do
    assert Anthropic.apply_service_tier(%{model: "claude-opus-5"}, service_tier: "auto") ==
             %{model: "claude-opus-5", service_tier: "auto"}
  end

  test "does not forward another provider's incompatible tier vocabulary" do
    body = %{model: "claude-opus-5"}
    assert Anthropic.apply_service_tier(body, service_tier: "priority") == body
    assert Anthropic.apply_service_tier(body, service_tier: "flex") == body
  end
end
