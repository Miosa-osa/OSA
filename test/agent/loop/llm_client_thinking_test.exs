defmodule OptimalSystemAgent.Agent.Loop.LLMClientThinkingTest do
  @moduledoc """
  `thinking_config/1` emits the thinking dialect the target model actually
  accepts.

  Anthropic removed the fixed thinking budget on the Claude 5 family and on
  Opus 4.7/4.8 — `{type: "enabled", budget_tokens: N}` returns a 400 there, so
  those models must always get plain `adaptive` and depth is steered by
  `output_config.effort` instead. Only Haiku 4.5 and older still take a budget.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Effort

  setup do
    prev_enabled = Application.get_env(:optimal_system_agent, :thinking_enabled)
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_effort = Application.get_env(:optimal_system_agent, :effort_level)
    prev_session = session_effort_level()

    Application.put_env(:optimal_system_agent, :thinking_enabled, true)
    Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

    on_exit(fn ->
      restore_session_effort_level(prev_session)
      restore(:thinking_enabled, prev_enabled)
      restore(:default_provider, prev_provider)
      restore(:effort_level, prev_effort)
    end)

    :ok
  end

  test "opus below ultra keeps adaptive thinking" do
    Effort.set(:high)

    assert LLMClient.thinking_config(%{provider: :anthropic, model: "claude-opus-4-8"}) ==
             %{type: "adaptive"}
  end

  test "opus at ultra stays adaptive — budget_tokens is a 400 on this model" do
    Effort.set(:ultra)

    assert LLMClient.thinking_config(%{provider: :anthropic, model: "claude-opus-4-8"}) ==
             %{type: "adaptive"}
  end

  test "the Claude 5 family never receives budget_tokens at any tier" do
    for model <- ["claude-opus-5", "claude-sonnet-5", "claude-fable-5"],
        tier <- [:medium, :high, :xhigh, :ultra] do
      Effort.set(tier)

      assert LLMClient.thinking_config(%{provider: :anthropic, model: model}) ==
               %{type: "adaptive"},
             "#{model} at #{tier} must be adaptive — Anthropic removed the fixed " <>
               "thinking budget on this model and rejects budget_tokens with a 400"
    end
  end

  test "budget-dialect models still use the effort thinking budget" do
    Effort.set(:high)
    cfg = LLMClient.thinking_config(%{provider: :anthropic, model: "claude-haiku-4-5"})

    assert cfg.type == "enabled"
    assert cfg.budget_tokens == Effort.thinking_budget()
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

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
