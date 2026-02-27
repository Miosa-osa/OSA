defmodule OptimalSystemAgent.Providers.AnthropicThinkingTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Anthropic

  describe "maybe_add_thinking/2" do
    test "adds enabled thinking with budget" do
      body = %{model: "claude-sonnet-4-6", max_tokens: 4096}
      thinking = %{type: "enabled", budget_tokens: 5000}

      result = Anthropic.maybe_add_thinking(body, thinking)
      assert result.thinking == %{type: "enabled", budget_tokens: 5000}
    end

    test "adds adaptive thinking" do
      body = %{model: "claude-opus-4-6", max_tokens: 4096}
      thinking = %{type: "adaptive"}

      result = Anthropic.maybe_add_thinking(body, thinking)
      assert result.thinking == %{type: "adaptive"}
    end

    test "no-ops when thinking is nil" do
      body = %{model: "claude-sonnet-4-6", max_tokens: 4096}
      result = Anthropic.maybe_add_thinking(body, nil)
      refute Map.has_key?(result, :thinking)
    end

    test "enforces minimum budget of 1024 for enabled mode" do
      body = %{model: "claude-sonnet-4-6", max_tokens: 4096}
      thinking = %{type: "enabled", budget_tokens: 500}

      result = Anthropic.maybe_add_thinking(body, thinking)
      assert result.thinking.budget_tokens == 1024
    end
  end

  describe "build_headers/2" do
    test "includes interleaved-thinking beta header when thinking enabled" do
      headers = Anthropic.build_headers("test-key", %{type: "enabled", budget_tokens: 5000})
      beta = Enum.find(headers, fn {k, _} -> k == "anthropic-beta" end)
      assert beta != nil
      {_, val} = beta
      assert val =~ "interleaved-thinking"
    end

    test "does not include beta header when thinking is nil" do
      headers = Anthropic.build_headers("test-key", nil)
      beta = Enum.find(headers, fn {k, _} -> k == "anthropic-beta" end)
      assert beta == nil
    end
  end

  describe "extract_thinking/1" do
    test "extracts thinking blocks from response" do
      resp = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me reason...", "signature" => "sig123"},
          %{"type" => "text", "text" => "Hello"}
        ]
      }

      blocks = Anthropic.extract_thinking(resp)
      assert length(blocks) == 1
      [block] = blocks
      assert block.thinking == "Let me reason..."
      assert block.signature == "sig123"
    end

    test "returns empty list when no thinking blocks" do
      resp = %{"content" => [%{"type" => "text", "text" => "Hello"}]}
      assert Anthropic.extract_thinking(resp) == []
    end

    test "returns empty list for nil content" do
      assert Anthropic.extract_thinking(%{}) == []
    end
  end

  describe "extract_usage/1" do
    test "extracts cache tokens when present" do
      resp = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_creation_input_tokens" => 20,
          "cache_read_input_tokens" => 10
        }
      }

      usage = Anthropic.extract_usage(resp)
      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
      assert usage.cache_creation_input_tokens == 20
      assert usage.cache_read_input_tokens == 10
    end

    test "works without cache tokens" do
      resp = %{"usage" => %{"input_tokens" => 100, "output_tokens" => 50}}
      usage = Anthropic.extract_usage(resp)
      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
      assert usage.cache_creation_input_tokens == 0
      assert usage.cache_read_input_tokens == 0
    end
  end

  describe "format_messages_with_thinking/1" do
    test "includes thinking blocks in assistant messages" do
      messages = [
        %{role: "user", content: "Hello"},
        %{
          role: "assistant",
          content: "Hi there",
          thinking_blocks: [
            %{type: "thinking", thinking: "reasoning...", signature: "sig1"}
          ]
        }
      ]

      formatted = Anthropic.format_messages(messages)
      assistant_msg = Enum.find(formatted, &(&1["role"] == "assistant"))
      assert is_list(assistant_msg["content"])
      assert length(assistant_msg["content"]) == 2

      thinking_block = Enum.find(assistant_msg["content"], &(&1["type"] == "thinking"))
      assert thinking_block["thinking"] == "reasoning..."
    end

    test "handles normal messages without thinking blocks" do
      messages = [%{role: "user", content: "Hello"}]
      formatted = Anthropic.format_messages(messages)
      assert [%{"role" => "user", "content" => "Hello"}] = formatted
    end
  end
end
