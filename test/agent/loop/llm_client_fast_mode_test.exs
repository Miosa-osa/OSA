defmodule OptimalSystemAgent.Agent.Loop.LLMClientFastModeTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.LLMClient

  setup do
    previous_effort = Application.get_env(:optimal_system_agent, :effort_level)
    previous_thinking = Application.get_env(:optimal_system_agent, :thinking_enabled)
    previous_provider = Application.get_env(:optimal_system_agent, :default_provider)

    Application.put_env(:optimal_system_agent, :thinking_enabled, true)
    Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
    Effort.set(:medium)

    on_exit(fn ->
      restore_env(:effort_level, previous_effort)
      restore_env(:thinking_enabled, previous_thinking)
      restore_env(:default_provider, previous_provider)
    end)

    :ok
  end

  test "fast mode disables extended thinking" do
    Effort.set(:low)

    assert LLMClient.thinking_config(%{provider: :anthropic, model: "claude-sonnet-4-6"}) == nil
  end

  test "non-fast mode keeps configured thinking" do
    Effort.set(:medium)

    assert %{type: "enabled", budget_tokens: 5_000} =
             LLMClient.thinking_config(%{provider: :anthropic, model: "claude-sonnet-4-6"})
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, value), do: Application.put_env(:optimal_system_agent, key, value)
end
