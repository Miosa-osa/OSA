defmodule OptimalSystemAgent.Agent.Loop.DoomLoopComputerUseTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.DoomLoop

  defp base_state do
    %{
      session_id: "test-cu",
      total_tool_calls: 0,
      recent_failure_signatures: [],
      messages: []
    }
  end

  test "check/3 counts computer_use calls toward total_tool_calls (accounting not bypassed)" do
    tc = %{id: "c1", name: "computer_use", arguments: %{"action" => "screenshot"}}
    result = {%{role: "tool", tool_call_id: "c1", content: "ok"}, "screenshot ok"}

    assert {:ok, new_state} = DoomLoop.check([{tc, result}], [tc], base_state())
    assert new_state.total_tool_calls == 1
  end

  test "check/3 keys on tool name+args, not on message thinking blocks (item 5)" do
    # A thinking-carrying assistant message in history must not confuse detection.
    tc = %{id: "c2", name: "computer_use", arguments: %{"action" => "click"}}
    result = {%{role: "tool", tool_call_id: "c2", content: "ok"}, "click ok"}

    state =
      Map.put(base_state(), :messages, [
        %{
          role: "assistant",
          content: "",
          thinking_blocks: [%{type: "thinking", thinking: "reason", signature: "s"}],
          tool_calls: [tc]
        }
      ])

    assert {:ok, new_state} = DoomLoop.check([{tc, result}], [tc], state)
    assert new_state.total_tool_calls == 1
  end
end
