defmodule OptimalSystemAgent.Providers.AnthropicInterleavedThinkingTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Anthropic

  describe "format_messages/1 interleaved thinking re-serialization" do
    test "signed thinking block survives a tool cycle: signature preserved, thinking first" do
      messages = [
        %{role: "user", content: "do it"},
        %{
          role: "assistant",
          content: "working",
          thinking_blocks: [%{type: "thinking", thinking: "reason", signature: "sig-abc"}],
          tool_calls: [%{id: "t1", name: "file_read", arguments: %{"path" => "/x"}}]
        },
        %{role: "tool", tool_call_id: "t1", content: "ok"}
      ]

      formatted = Anthropic.format_messages(messages)
      assistant = Enum.find(formatted, &(&1["role"] == "assistant"))
      blocks = assistant["content"]

      # thinking block must be FIRST and carry its signature verbatim
      assert [%{"type" => "thinking"} = tb | _rest] = blocks
      assert tb["thinking"] == "reason"
      assert tb["signature"] == "sig-abc"

      # tool_use block also present (interleaved thinking + tool call coexist)
      assert Enum.any?(blocks, &(&1["type"] == "tool_use" and &1["id"] == "t1"))
    end

    test "unsigned thinking block is dropped (Anthropic rejects unsigned thinking on input)" do
      messages = [
        %{
          role: "assistant",
          content: "hi",
          thinking_blocks: [%{type: "thinking", thinking: "unsigned", signature: nil}]
        }
      ]

      formatted = Anthropic.format_messages(messages)
      assistant = Enum.find(formatted, &(&1["role"] == "assistant"))
      refute Enum.any?(assistant["content"], &(&1["type"] == "thinking"))
      assert Enum.any?(assistant["content"], &(&1["type"] == "text"))
    end
  end
end
