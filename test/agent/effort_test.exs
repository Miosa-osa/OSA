defmodule OptimalSystemAgent.Agent.EffortTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    previous_session = session_effort_level()
    Effort.set(:medium)

    on_exit(fn ->
      restore_session_effort_level(previous_session)

      if previous do
        Application.put_env(:optimal_system_agent, :effort_level, previous)
      else
        Application.delete_env(:optimal_system_agent, :effort_level)
      end
    end)

    :ok
  end

  test "fast mode uses the low-latency profile" do
    Effort.set(:low)

    assert Effort.fast_mode?()
    assert Effort.thinking_budget() == 0
    assert Effort.max_iterations() == 30
    assert Effort.max_response_tokens() == 32_768
    assert Effort.tool_budget() == 18
  end

  test "toggle_fast switches between low and medium" do
    Effort.set(:medium)

    assert :ok = Effort.toggle_fast()
    assert Effort.current() == :low

    assert :ok = Effort.toggle_fast()
    assert Effort.current() == :medium
  end

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
