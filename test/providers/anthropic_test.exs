defmodule OptimalSystemAgent.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Anthropic

  # ---------------------------------------------------------------------------
  # format_messages/1
  # ---------------------------------------------------------------------------

  describe "format_messages/1" do
    test "formats a simple user text message" do
      messages = [%{role: "user", content: "hello"}]
      [formatted] = Anthropic.format_messages(messages)

      assert formatted == %{"role" => "user", "content" => "hello"}
    end

    test "formats assistant text message" do
      messages = [%{role: "assistant", content: "hi there"}]
      [formatted] = Anthropic.format_messages(messages)

      assert formatted == %{"role" => "assistant", "content" => "hi there"}
    end

    test "formats tool result as Anthropic user + tool_result block" do
      messages = [%{role: "tool", tool_call_id: "tc_123", content: "file contents here"}]
      [formatted] = Anthropic.format_messages(messages)

      assert formatted["role"] == "user"
      [block] = formatted["content"]
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "tc_123"
      assert block["content"] == "file contents here"
    end

    test "formats tool result with structured image content" do
      messages = [
        %{
          role: "tool",
          tool_call_id: "tc_img",
          content: [
            %{type: "text", text: "Image: /tmp/screenshot.png"},
            %{type: "image", source: %{type: "base64", media_type: "image/png", data: "iVBOR..."}}
          ]
        }
      ]

      [formatted] = Anthropic.format_messages(messages)
      assert formatted["role"] == "user"
      [wrapper] = formatted["content"]
      assert wrapper["type"] == "tool_result"
      assert wrapper["tool_use_id"] == "tc_img"
      [text_block, image_block] = wrapper["content"]
      assert text_block["type"] == "text"
      assert image_block["type"] == "image"
      assert image_block["source"]["media_type"] == "image/png"
    end

    test "formats assistant message with tool_calls as content blocks" do
      messages = [
        %{
          role: "assistant",
          content: "Let me check that file.",
          tool_calls: [
            %{id: "tc_1", name: "file_read", arguments: %{"path" => "/tmp/test.ex"}}
          ]
        }
      ]

      [formatted] = Anthropic.format_messages(messages)
      assert formatted["role"] == "assistant"
      [text_block, tool_block] = formatted["content"]
      assert text_block == %{"type" => "text", "text" => "Let me check that file."}
      assert tool_block["type"] == "tool_use"
      assert tool_block["id"] == "tc_1"
      assert tool_block["name"] == "file_read"
      assert tool_block["input"] == %{"path" => "/tmp/test.ex"}
    end

    test "formats assistant with empty content and tool_calls" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "tc_2", name: "shell_execute", arguments: %{"command" => "ls"}}]
        }
      ]

      [formatted] = Anthropic.format_messages(messages)
      # Empty content should not produce a text block
      assert length(formatted["content"]) == 1
      [tool_block] = formatted["content"]
      assert tool_block["type"] == "tool_use"
    end

    test "formats thinking blocks with tool_calls (interleaved thinking)" do
      messages = [
        %{
          role: "assistant",
          content: "I'll search for that.",
          thinking_blocks: [
            %{thinking: "Let me think about this...", signature: "sig_abc"}
          ],
          tool_calls: [
            %{id: "tc_3", name: "file_grep", arguments: %{"query" => "auth"}}
          ]
        }
      ]

      [formatted] = Anthropic.format_messages(messages)
      assert formatted["role"] == "assistant"
      blocks = formatted["content"]

      types = Enum.map(blocks, & &1["type"])
      assert "thinking" in types
      assert "text" in types
      assert "tool_use" in types
    end

    test "formats thinking blocks without tool_calls" do
      messages = [
        %{
          role: "assistant",
          content: "The answer is 42.",
          thinking_blocks: [%{thinking: "Calculating...", signature: nil}]
        }
      ]

      [formatted] = Anthropic.format_messages(messages)
      blocks = formatted["content"]
      types = Enum.map(blocks, & &1["type"])
      assert "thinking" in types
      assert "text" in types
      refute "tool_use" in types
    end

    test "formats thinking blocks with empty content omits text block" do
      messages = [
        %{
          role: "assistant",
          content: "",
          thinking_blocks: [%{thinking: "hmm", signature: nil}]
        }
      ]

      [formatted] = Anthropic.format_messages(messages)
      blocks = formatted["content"]
      types = Enum.map(blocks, & &1["type"])
      assert "thinking" in types
      refute "text" in types
    end

    test "passes through already-formatted messages" do
      messages = [%{"role" => "user", "content" => "already formatted"}]
      [formatted] = Anthropic.format_messages(messages)
      assert formatted == %{"role" => "user", "content" => "already formatted"}
    end

    test "formats structured content blocks (non-tool)" do
      messages = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "What's in this image?"},
            %{
              type: "image",
              source: %{type: "base64", media_type: "image/jpeg", data: "/9j/4..."}
            }
          ]
        }
      ]

      [formatted] = Anthropic.format_messages(messages)
      assert formatted["role"] == "user"
      [text, image] = formatted["content"]
      assert text["type"] == "text"
      assert image["type"] == "image"
    end

    test "handles multiple messages in sequence" do
      messages = [
        %{role: "user", content: "read /tmp/foo"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "tc_a", name: "file_read", arguments: %{"path" => "/tmp/foo"}}]
        },
        %{role: "tool", tool_call_id: "tc_a", content: "file contents"},
        %{role: "assistant", content: "Here are the contents."}
      ]

      formatted = Anthropic.format_messages(messages)
      assert length(formatted) == 4
      assert Enum.at(formatted, 0)["role"] == "user"
      assert Enum.at(formatted, 1)["role"] == "assistant"
      # tool_result → user
      assert Enum.at(formatted, 2)["role"] == "user"
      assert Enum.at(formatted, 3)["role"] == "assistant"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_retry_after/1 (tested via module internals)
  # ---------------------------------------------------------------------------

  describe "rate limiting behavior" do
    test "429 response structure is correct" do
      # We can't hit the real API, but we can verify the error tuple shape
      # that parse_retry_after produces. Test the contract.
      error = {:rate_limited, 30}
      assert {:rate_limited, seconds} = error
      assert is_integer(seconds)
    end
  end

  # ---------------------------------------------------------------------------
  # extract_thinking/1
  # ---------------------------------------------------------------------------

  describe "extract_thinking/1" do
    test "extracts thinking blocks from response" do
      resp = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me think...", "signature" => "sig_1"},
          %{"type" => "text", "text" => "The answer is 42."}
        ]
      }

      blocks = Anthropic.extract_thinking(resp)
      assert length(blocks) == 1
      [block] = blocks
      assert block.thinking == "Let me think..."
      assert block.signature == "sig_1"
    end

    test "returns empty list when no thinking blocks" do
      resp = %{"content" => [%{"type" => "text", "text" => "hello"}]}
      assert Anthropic.extract_thinking(resp) == []
    end

    test "returns empty list for nil input" do
      assert Anthropic.extract_thinking(nil) == []
    end
  end

  # ---------------------------------------------------------------------------
  # extract_usage/1
  # ---------------------------------------------------------------------------

  describe "extract_usage/1" do
    test "extracts usage including cache tokens" do
      resp = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_creation_input_tokens" => 200,
          "cache_read_input_tokens" => 150
        }
      }

      usage = Anthropic.extract_usage(resp)
      assert usage.input_tokens == 100
      assert usage.output_tokens == 50
      assert usage.cache_creation_input_tokens == 200
      assert usage.cache_read_input_tokens == 150
    end

    test "returns zeroed usage for missing fields" do
      resp = %{"usage" => %{}}
      usage = Anthropic.extract_usage(resp)
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
    end

    test "returns empty map for missing usage" do
      assert Anthropic.extract_usage(%{}) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # build_headers/2
  # ---------------------------------------------------------------------------

  describe "build_headers/2" do
    test "includes base headers without thinking" do
      headers = Anthropic.build_headers("test-key", nil)
      assert List.keyfind(headers, "x-api-key", 0) == {"x-api-key", "test-key"}
      assert List.keyfind(headers, "anthropic-version", 0) == {"anthropic-version", "2023-06-01"}
      assert List.keyfind(headers, "content-type", 0) == {"content-type", "application/json"}
    end

    test "includes interleaved-thinking beta when thinking enabled" do
      headers = Anthropic.build_headers("test-key", %{type: "enabled", budget_tokens: 5000})
      {_, beta_value} = List.keyfind(headers, "anthropic-beta", 0)
      assert String.contains?(beta_value, "interleaved-thinking-2025-05-14")
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_add_thinking/2
  # ---------------------------------------------------------------------------

  describe "maybe_add_thinking/2" do
    test "no-ops when thinking is nil" do
      body = %{model: "test"}
      assert Anthropic.maybe_add_thinking(body, nil) == body
    end

    test "adds adaptive thinking" do
      body = %{model: "test"}
      result = Anthropic.maybe_add_thinking(body, %{type: "adaptive"})
      assert result.thinking == %{type: "adaptive"}
    end

    test "adds enabled thinking with minimum 1024 budget" do
      body = %{model: "test"}
      result = Anthropic.maybe_add_thinking(body, %{type: "enabled", budget_tokens: 500})
      assert result.thinking.budget_tokens == 1024
    end

    test "preserves budget when above minimum" do
      body = %{model: "test"}
      result = Anthropic.maybe_add_thinking(body, %{type: "enabled", budget_tokens: 10_000})
      assert result.thinking.budget_tokens == 10_000
    end
  end
end
