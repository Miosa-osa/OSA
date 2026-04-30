defmodule OptimalSystemAgent.Agent.Loop.ToolFilterTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.ToolFilter

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    Effort.set(:medium)

    on_exit(fn ->
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

    filtered = ToolFilter.filter(tools, %{provider: :anthropic, messages: []})

    assert length(filtered) == 6

    assert Enum.map(filtered, & &1.name) ==
             ~w(file_read file_write file_edit shell_execute ask_user computer_use)
  end

  test "medium mode does not trim non-local providers" do
    Effort.set(:medium)
    tools = Enum.map(1..12, &%{name: "tool_#{&1}"})

    assert ToolFilter.filter(tools, %{provider: :anthropic, messages: []}) == tools
  end
end
