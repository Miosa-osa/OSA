defmodule OptimalSystemAgent.Providers.OpenAIResponsesTest do
  @moduledoc """
  The Responses API adapter.

  These tests exist because Responses differs from chat/completions in ways
  that fail *silently* rather than loudly: a system message left in `input`
  still produces a plausible answer, and a tool sent in the nested
  chat/completions shape is accepted and then simply never called. Both look
  like "the model is being unhelpful" rather than like a bug, so each is
  pinned here explicitly.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.OpenAIResponses

  describe "request shaping" do
    test "system messages become top-level instructions, not input items" do
      # Left in `input`, OSA's steering would be demoted to ordinary
      # conversation text — the model would still answer, just without being
      # steered, which is exactly the kind of regression that goes unnoticed.
      messages = [
        %{role: "system", content: "You are precise."},
        %{role: "user", content: "hi"}
      ]

      body = OpenAIResponses.build_body("gpt-5.2-codex", messages, [], false)

      assert body.instructions == "You are precise."
      refute Enum.any?(body.input, &(&1[:role] == "system"))
      assert [%{type: "message", role: "user"}] = body.input
    end

    test "multiple system messages are joined, never dropped" do
      messages = [
        %{role: "system", content: "First."},
        %{role: "system", content: "Second."},
        %{role: "user", content: "hi"}
      ]

      {instructions, _} = OpenAIResponses.split_instructions(messages)

      assert instructions == "First.\n\nSecond."
    end

    test "no system message means no instructions key at all" do
      body = OpenAIResponses.build_body("m", [%{role: "user", content: "hi"}], [], false)
      refute Map.has_key?(body, :instructions)
    end

    test "tools are flattened out of the chat/completions nesting" do
      # Sent nested, OpenAI accepts the request and silently never calls the
      # tool. That presents as "the model ignores tools", not as an error.
      tools = [
        %{
          name: "read_file",
          description: "Read a file",
          parameters: %{"type" => "object", "properties" => %{}}
        }
      ]

      [tool] = OpenAIResponses.format_tools(tools)

      assert tool["type"] == "function"
      assert tool["name"] == "read_file"
      assert tool["description"] == "Read a file"
      assert is_map(tool["parameters"])
      refute Map.has_key?(tool, "function"), "Responses takes a FLAT tool schema"
    end

    test "an assistant tool call round-trips as a function_call item" do
      messages = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "call_1", name: "read_file", arguments: %{"path" => "a.txt"}}]
        }
      ]

      body = OpenAIResponses.build_body("m", messages, [], false)

      assert [%{type: "function_call", call_id: "call_1", name: "read_file", arguments: args}] =
               body.input

      assert Jason.decode!(args) == %{"path" => "a.txt"}
    end

    test "a tool result becomes a function_call_output keyed by call id" do
      messages = [%{role: "tool", tool_call_id: "call_1", content: "file contents"}]
      body = OpenAIResponses.build_body("m", messages, [], false)

      assert [%{type: "function_call_output", call_id: "call_1", output: "file contents"}] =
               body.input
    end

    test "a screenshot tool result preserves the call output and sends an input_image" do
      messages = [
        %{
          role: "tool",
          tool_call_id: "call_vision",
          content: [
            %{type: "text", text: "Image: /tmp/screen.png"},
            %{type: "image", source: %{type: "base64", media_type: "image/png", data: "aGVsbG8="}}
          ]
        }
      ]

      body = OpenAIResponses.build_body("gpt-5.6-sol", messages, [], true)

      assert [%{type: "function_call_output", call_id: "call_vision", output: output}] =
               body.input

      assert Enum.any?(output, &(&1.type == "input_image"))
    end

    test "user image content is encoded for Responses rather than flattened" do
      messages = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "look"},
            %{type: "image", source: %{media_type: "image/jpeg", data: "YWJj"}}
          ]
        }
      ]

      body = OpenAIResponses.build_body("gpt-5.6-sol", messages, [], false)

      assert [%{content: [%{type: "input_text", text: "look"}, %{type: "input_image"}]}] =
               body.input
    end

    test "an assistant turn with both text and calls emits both, in order" do
      messages = [
        %{
          role: "assistant",
          content: "Let me look.",
          tool_calls: [%{id: "c1", name: "t", arguments: %{}}]
        }
      ]

      body = OpenAIResponses.build_body("m", messages, [], false)

      assert [%{type: "message"}, %{type: "function_call"}] = body.input
    end

    test "streaming and max tokens use the Responses spellings" do
      body =
        OpenAIResponses.build_body("m", [%{role: "user", content: "x"}], [max_tokens: 100], true)

      assert body.stream == true
      assert body.max_output_tokens == 100
      refute Map.has_key?(body, :max_tokens)
    end

    test "Codex requests explicitly disable server-side storage" do
      body = OpenAIResponses.build_body("m", [%{role: "user", content: "x"}], [], true)

      assert body.store == false
    end

    test "passes OpenAI Fast processing through as a service tier" do
      body =
        OpenAIResponses.build_body(
          "gpt-5.6-sol",
          [%{role: "user", content: "x"}],
          [service_tier: "fast"],
          true
        )

      assert body.service_tier == "fast"
    end
  end

  describe "headers" do
    test "carry the bearer token, account id and originator" do
      headers = OpenAIResponses.headers("tok", account_id: "acct_123", originator: "osa")

      assert {"authorization", "Bearer tok"} in headers
      assert {"chatgpt-account-id", "acct_123"} in headers
      assert {"originator", "osa"} in headers
    end

    test "omit the account header entirely when there is no account id" do
      # Sending an empty account id is worse than sending none: it is a
      # malformed identity rather than an absent one.
      headers = OpenAIResponses.headers("tok", [])
      refute Enum.any?(headers, fn {k, _} -> k == "chatgpt-account-id" end)
    end
  end

  describe "non-streaming responses" do
    test "extracts text, tool calls and usage" do
      resp = %{
        "status" => "completed",
        "output" => [
          %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hello"}]},
          %{
            "type" => "function_call",
            "call_id" => "call_9",
            "name" => "read_file",
            "arguments" => ~s({"path":"a.txt"})
          }
        ],
        "usage" => %{
          "input_tokens" => 12,
          "output_tokens" => 5,
          "input_tokens_details" => %{"cached_tokens" => 4}
        }
      }

      result = OpenAIResponses.parse_response(resp, [])

      assert result.content == "Hello"

      assert [%{id: "call_9", name: "read_file", arguments: %{"path" => "a.txt"}}] =
               result.tool_calls

      assert result.usage.input_tokens == 12
      assert result.usage.output_tokens == 5
      # `:cache_read_input_tokens`, not `:cached_tokens`. CacheAttribution reads
      # the former, so the old key collected the number and nothing ever saw it —
      # this assertion pinned that gap in place.
      assert result.usage.cache_read_input_tokens == 4
      assert result.stop_reason == "tool_calls"
    end

    test "concatenates multiple output_text parts" do
      resp = %{
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "Hel"},
              %{"type" => "output_text", "text" => "lo"}
            ]
          }
        ]
      }

      assert OpenAIResponses.parse_response(resp, []).content == "Hello"
    end

    test "an incomplete response reports WHY rather than looking like a normal stop" do
      # Hitting the output cap and finishing normally are different events and
      # must not be conflated — one means the answer is truncated.
      resp = %{
        "status" => "incomplete",
        "output" => [],
        "incomplete_details" => %{"reason" => "max_output_tokens"}
      }

      assert OpenAIResponses.parse_response(resp, []).stop_reason == "max_output_tokens"
    end

    test "malformed tool arguments degrade to empty rather than crashing the turn" do
      resp = %{
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "c",
            "name" => "t",
            "arguments" => "{not json"
          }
        ]
      }

      assert [%{arguments: %{}}] = OpenAIResponses.parse_response(resp, []).tool_calls
    end
  end

  describe "usage normalisation" do
    test "Responses token keys are mapped onto OSA's names" do
      # Responses says input_tokens/output_tokens; chat/completions says
      # prompt_tokens/completion_tokens. Accounting must never have to care.
      usage = OpenAIResponses.parse_usage(%{"input_tokens" => 7, "output_tokens" => 3}, [], "hi")

      assert usage.input_tokens == 7
      assert usage.output_tokens == 3
      refute Map.has_key?(usage, :estimated)
    end

    test "missing usage falls back to an estimate marked as such" do
      # Recording a flat zero would silently corrupt budget accounting.
      usage = OpenAIResponses.parse_usage(nil, [%{role: "user", content: "hello"}], "world")

      assert usage.estimated == true
      assert usage.input_tokens > 0
    end
  end

  describe "SSE streaming" do
    defp drain(chunks) do
      parent = self()
      callback = fn event -> send(parent, event) end

      acc = %{content: "", tool_calls: [], usage: %{}, stop_reason: nil, buffer: ""}
      Enum.reduce(chunks, acc, &OpenAIResponses.consume(&2, &1, callback))
    end

    defp event(type, payload) do
      "data: " <> Jason.encode!(Map.put(payload, "type", type)) <> "\n\n"
    end

    test "assembles text deltas and emits them live" do
      acc =
        drain([
          event("response.output_text.delta", %{"delta" => "Hel"}),
          event("response.output_text.delta", %{"delta" => "lo"})
        ])

      assert acc.content == "Hello"
      assert_received {:text_delta, "Hel"}
      assert_received {:text_delta, "lo"}
    end

    test "a chunk boundary splitting an SSE frame does not lose or corrupt it" do
      # Real chunk boundaries fall anywhere, including mid-JSON. Parsing
      # optimistically here drops tokens at random under load, which is
      # miserable to diagnose after the fact.
      full = event("response.output_text.delta", %{"delta" => "Hello"})
      {a, b} = String.split_at(full, 20)

      assert drain([a, b]).content == "Hello"
    end

    test "collects tool calls from completed output items" do
      acc =
        drain([
          event("response.output_item.done", %{
            "item" => %{
              "type" => "function_call",
              "call_id" => "c1",
              "name" => "read_file",
              "arguments" => ~s({"path":"x"})
            }
          })
        ])

      assert [%{id: "c1", name: "read_file", arguments: %{"path" => "x"}}] = acc.tool_calls
    end

    test "a completed message output item does not become a phantom tool call" do
      acc =
        drain([
          event("response.output_item.done", %{
            "item" => %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "hi"}]
            }
          })
        ])

      assert acc.tool_calls == []
    end

    test "captures usage from response.completed" do
      acc =
        drain([
          event("response.completed", %{
            "response" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 2}}
          })
        ])

      assert acc.usage["input_tokens"] == 10
    end

    test "a truncated stream records why it stopped" do
      acc =
        drain([
          event("response.incomplete", %{
            "response" => %{"incomplete_details" => %{"reason" => "max_output_tokens"}}
          })
        ])

      assert acc.stop_reason == "max_output_tokens"
    end

    test "unknown event types are ignored rather than breaking the stream" do
      # The API emits many events OSA does not render. Reacting to them would
      # only create ways to double-count.
      acc =
        drain([
          event("response.reasoning_summary_part.added", %{"foo" => 1}),
          event("response.output_text.delta", %{"delta" => "ok"})
        ])

      assert acc.content == "ok"
    end

    test "a malformed frame does not kill a stream that is otherwise fine" do
      acc =
        drain([
          "data: {not json\n\n",
          event("response.output_text.delta", %{"delta" => "still here"})
        ])

      assert acc.content == "still here"
    end

    test "[DONE] and empty frames are tolerated" do
      acc =
        drain([
          "data: [DONE]\n\n",
          "\n\n",
          event("response.output_text.delta", %{"delta" => "x"})
        ])

      assert acc.content == "x"
    end
  end
end
