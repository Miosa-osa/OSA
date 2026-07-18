defmodule OptimalSystemAgent.Agent.Loop.InterruptTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop

  @cancel_table :osa_cancel_flags

  defp base_state(messages) do
    %{
      session_id: "interrupt-test-#{System.unique_integer([:positive])}",
      iteration: 3,
      messages: messages,
      model: nil,
      provider: nil
    }
  end

  test "cancelled turn ends with a user-role interrupt marker" do
    state = base_state([%{role: "user", content: "do the thing"}])
    :ets.insert(@cancel_table, {state.session_id, true})

    {response, new_state} = ReactLoop.run(state)

    assert response == "[Request interrupted by user]"

    assert List.last(new_state.messages) ==
             %{role: "user", content: "[Request interrupted by user]"}
  end

  test "orphaned tool_use gets an interrupted tool_result and the tool-use marker" do
    tc = %{id: "tc_1", name: "shell_execute", arguments: %{}}

    msgs = [
      %{role: "user", content: "run it"},
      %{role: "assistant", content: "", tool_calls: [tc]}
    ]

    state = base_state(msgs)
    :ets.insert(@cancel_table, {state.session_id, true})

    {response, new_state} = ReactLoop.run(state)

    assert response == "[Request interrupted by user for tool use]"
    [tool_result, marker] = Enum.take(new_state.messages, -2)
    assert tool_result.role == "tool"
    assert tool_result.tool_call_id == "tc_1"
    assert tool_result.content =~ "Interrupted by user"
    assert marker == %{role: "user", content: "[Request interrupted by user for tool use]"}
  end

  test "interrupt_markers/0 exposes both marker strings (TUI contract)" do
    assert "[Request interrupted by user]" in ReactLoop.interrupt_markers()
    assert "[Request interrupted by user for tool use]" in ReactLoop.interrupt_markers()
  end
end
