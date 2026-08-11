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

    # `scaffold: true` is part of the marker's contract, not incidental: it is
    # what lets `/undo` skip loop-injected text by flag instead of by matching
    # the marker string. Asserted as an exact map so a silently-dropped flag
    # fails here.
    assert List.last(new_state.messages) ==
             %{role: "user", content: "[Request interrupted by user]", scaffold: true}
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

    assert marker == %{
             role: "user",
             content: "[Request interrupted by user for tool use]",
             scaffold: true
           }
  end

  # The orphan fill used to look at `List.last/1` only. `finalize_interrupt/2`
  # appends the partial assistant TEXT before calling it, so an assistant
  # message carrying both text and tool calls stops being last and its
  # `tool_use` blocks were never answered. A strict provider (Anthropic,
  # Gemini) then rejects the request — and since the transcript is persisted,
  # it rejects it again on EVERY later turn, permanently.
  test "an orphaned tool_use that is NOT the last message is still filled" do
    tc = %{id: "tc_orphan", name: "shell_execute", arguments: %{}}

    msgs = [
      %{role: "user", content: "run it"},
      %{role: "assistant", content: "on it — ", tool_calls: [tc]},
      # Anything at all after the tool-call message hid the orphan from the
      # old `List.last/1` check. Streamed partial text is the real-world one.
      %{role: "assistant", content: "…partial text that streamed before the abort"}
    ]

    state = base_state(msgs)
    :ets.insert(@cancel_table, {state.session_id, true})

    {response, new_state} = ReactLoop.run(state)

    ids =
      for m <- new_state.messages,
          (m[:role] || m["role"]) == "tool",
          do: m[:tool_call_id] || m["tool_call_id"]

    assert "tc_orphan" in ids,
           "every unanswered tool_use must get a synthetic tool_result or the " <>
             "persisted transcript is permanently invalid"

    # And it must sit directly after the assistant message that owns it —
    # Anthropic requires the tool_result in the immediately following message.
    idx = Enum.find_index(new_state.messages, &((&1[:role] || &1["role"]) == "tool"))
    owner = Enum.at(new_state.messages, idx - 1)
    assert owner[:tool_calls] == [tc]

    assert response == "[Request interrupted by user for tool use]"
  end

  test "an ANSWERED tool_use is not given a second, synthetic result" do
    tc = %{id: "tc_done", name: "read_file", arguments: %{}}

    msgs = [
      %{role: "user", content: "read it"},
      %{role: "assistant", content: "", tool_calls: [tc]},
      %{role: "tool", tool_call_id: "tc_done", content: "file contents"},
      %{role: "assistant", content: "here is what I found"}
    ]

    state = base_state(msgs)
    :ets.insert(@cancel_table, {state.session_id, true})

    {_response, new_state} = ReactLoop.run(state)

    results = Enum.filter(new_state.messages, &((&1[:role] || &1["role"]) == "tool"))
    assert length(results) == 1
    assert hd(results).content == "file contents"
  end

  test "orphans in several assistant messages are all filled" do
    msgs = [
      %{role: "user", content: "go"},
      %{role: "assistant", content: "", tool_calls: [%{id: "a1", name: "t", arguments: %{}}]},
      %{role: "assistant", content: "", tool_calls: [%{id: "b1", name: "t", arguments: %{}}]},
      %{role: "assistant", content: "trailing text"}
    ]

    state = base_state(msgs)
    :ets.insert(@cancel_table, {state.session_id, true})

    {_response, new_state} = ReactLoop.run(state)

    ids =
      for m <- new_state.messages,
          (m[:role] || m["role"]) == "tool",
          do: m[:tool_call_id] || m["tool_call_id"]

    assert Enum.sort(ids) == ["a1", "b1"]
  end

  test "interrupt_markers/0 exposes both marker strings (TUI contract)" do
    assert "[Request interrupted by user]" in ReactLoop.interrupt_markers()
    assert "[Request interrupted by user for tool use]" in ReactLoop.interrupt_markers()
  end
end
