defmodule OptimalSystemAgent.Agent.Loop.LLMClientThinkingTest do
  @moduledoc """
  `thinking_config/1` honors the effort ladder — including on opus, which uses
  adaptive thinking by default but is forced to an explicit max budget at `:ultra`
  so ultra visibly thinks harder on opus too.
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

  test "opus at ultra forces an explicit max thinking budget" do
    Effort.set(:ultra)

    assert LLMClient.thinking_config(%{provider: :anthropic, model: "claude-opus-4-8"}) ==
             %{type: "enabled", budget_tokens: 64_000}
  end

  test "non-opus uses the effort thinking budget at every tier" do
    Effort.set(:high)
    cfg = LLMClient.thinking_config(%{provider: :anthropic, model: "claude-sonnet-5"})

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
