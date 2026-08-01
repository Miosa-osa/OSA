defmodule OptimalSystemAgent.Agent.Loop.LLMClientFastModeTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.LLMClient

  setup do
    previous_effort = Application.get_env(:optimal_system_agent, :effort_level)
    previous_session_effort = session_effort_level()
    previous_thinking = Application.get_env(:optimal_system_agent, :thinking_enabled)
    previous_provider = Application.get_env(:optimal_system_agent, :default_provider)

    Application.put_env(:optimal_system_agent, :thinking_enabled, true)
    Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
    Effort.set(:medium)

    on_exit(fn ->
      restore_session_effort_level(previous_session_effort)
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

  # Which thinking DIALECT a model speaks is a model fact, not an effort decision.
  # Anthropic removed the fixed thinking budget on the Claude 5 family (and on
  # Opus/Sonnet 4.6, where it is deprecated): sending
  # `{type: "enabled", budget_tokens: N}` to those models is a hard 400, not a
  # degraded response. So "non-fast mode keeps thinking" must assert the
  # PER-MODEL shape, not one hardcoded shape for every model.
  test "non-fast mode keeps thinking, in the dialect the model actually speaks" do
    Effort.set(:medium)

    # Adaptive family — budget_tokens would be a 400. Depth is steered by effort.
    for model <- ["claude-opus-5", "claude-sonnet-5", "claude-sonnet-4-6"] do
      assert %{type: "adaptive"} =
               LLMClient.thinking_config(%{provider: :anthropic, model: model}),
             "expected adaptive thinking for #{model}"
    end

    # Haiku 4.5 predates adaptive thinking and still takes an explicit budget.
    assert %{type: "enabled", budget_tokens: 5_000} =
             LLMClient.thinking_config(%{provider: :anthropic, model: "claude-haiku-4-5"})
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp session_effort_level do
    case :ets.whereis(:osa_settings) do
      :undefined ->
        :missing

      _ ->
        case :ets.lookup(:osa_settings, {:session, :effort_level}) do
          [{{:session, :effort_level}, value}] -> {:value, value}
          _ -> :missing
        end
    end
  end

  defp restore_session_effort_level(:missing) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.delete(:osa_settings, {:session, :effort_level})
    end
  end

  defp restore_session_effort_level({:value, value}) do
    if :ets.whereis(:osa_settings) != :undefined do
      :ets.insert(:osa_settings, {{:session, :effort_level}, value})
    end
  end
end
