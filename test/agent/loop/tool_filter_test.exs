defmodule OptimalSystemAgent.Agent.Loop.ToolFilterTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.ToolFilter

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

  test "fast mode applies an aggressive tool budget" do
    Effort.set(:low)

    tools =
      ~w(file_read file_write file_edit shell_execute ask_user computer_use memory_recall web_search git diff grep)
      |> Enum.map(&%{name: &1})

    filtered =
      ToolFilter.filter(tools, %{
        provider: :anthropic,
        messages: [%{role: "user", content: "fix this code and run tests"}]
      })

    assert length(filtered) <= Effort.tool_budget()
    names = Enum.map(filtered, & &1.name)
    assert "file_read" in names
    assert "shell_execute" in names
    assert "git" in names
  end

  test "fast mode keeps full tool list when intent is unclear" do
    Effort.set(:low)
    tools = Enum.map(1..12, &%{name: "tool_#{&1}"})

    assert ToolFilter.filter(tools, %{
             provider: :anthropic,
             messages: [%{role: "user", content: "hello"}]
           }) == tools
  end

  test "medium mode does not trim non-local providers" do
    Effort.set(:medium)
    tools = Enum.map(1..12, &%{name: "tool_#{&1}"})

    assert ToolFilter.filter(tools, %{provider: :anthropic, messages: []}) == tools
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
