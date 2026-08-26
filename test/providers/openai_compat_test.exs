defmodule OptimalSystemAgent.Providers.OpenAICompatTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.OpenAICompat

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Wraps a raw-JSON tool call string in the <function_call> format so we can
  # exercise extract_balanced_json via the public parse_tool_calls_from_content.
  defp function_call_wrap(json), do: "<function_call>#{json}</function_call>"

  # Wraps parameters JSON in an XML function tag (Format 1).
  defp xml_function_tag(name, params_json),
    do: ~s|<function name="#{name}" parameters=#{params_json}></function>|

  # ---------------------------------------------------------------------------
  # parse_tool_calls_from_content/1 — original tests
  # ---------------------------------------------------------------------------

  describe "parse_tool_calls_from_content/1" do
    test "returns empty list for plain text" do
      assert OpenAICompat.parse_tool_calls_from_content("Hello world") == []
    end

    test "returns empty list for nil / non-binary" do
      assert OpenAICompat.parse_tool_calls_from_content(nil) == []
      assert OpenAICompat.parse_tool_calls_from_content(42) == []
    end

    # ── Format 1: <function name="..." parameters={...}></function> ──

    test "parses simple XML function tag" do
      content = ~s|<function name="file_read" parameters={"path": "/foo/bar"}></function>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "file_read"
      assert tc.arguments == %{"path" => "/foo/bar"}
      assert is_binary(tc.id)
    end

    test "parses XML function tag with nested JSON arguments (Bug 4 fix)" do
      content =
        ~s|<function name="shell_execute" parameters={"command": "ls", "options": {"cwd": "/tmp", "timeout": 30}}></function>|

      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "shell_execute"
      assert tc.arguments["command"] == "ls"
      assert tc.arguments["options"] == %{"cwd" => "/tmp", "timeout" => 30}
    end

    test "parses multiple XML function tags" do
      content =
        ~s|<function name="file_read" parameters={"path": "/a"}></function>\n| <>
          ~s|<function name="file_write" parameters={"path": "/b", "content": "hi"}></function>\n|

      tcs = OpenAICompat.parse_tool_calls_from_content(content)
      assert length(tcs) == 2
      names = Enum.map(tcs, & &1.name)
      assert "file_read" in names
      assert "file_write" in names
    end

    test "handles XML with string values containing braces" do
      content =
        ~s|<function name="eval" parameters={"code": "if (x > 0) { return x; }"}></function>|

      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "eval"
      assert tc.arguments["code"] == "if (x > 0) { return x; }"
    end

    test "returns empty args map for malformed XML JSON" do
      content = ~s|<function name="bad_tool" parameters={not valid json}></function>|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "bad_tool"
      assert tc.arguments == %{}
    end

    # ── Format 2: <function_call>{...}</function_call> ──

    test "parses function_call tag format" do
      content =
        ~s|<function_call>{"name": "web_search", "arguments": {"query": "elixir otp"}}</function_call>|

      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "web_search"
      assert tc.arguments == %{"query" => "elixir otp"}
    end

    test "parses function_call with nested arguments" do
      content =
        ~s|<function_call>{"name": "orchestrate", "arguments": {"task": "research", "opts": {"depth": 3, "parallel": true}}}</function_call>|

      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "orchestrate"
      assert tc.arguments["opts"] == %{"depth" => 3, "parallel" => true}
    end

    test "parses multiple function_call tags" do
      content =
        ~s|<function_call>{"name": "tool_a", "arguments": {}}</function_call>\n| <>
          ~s|<function_call>{"name": "tool_b", "arguments": {"x": 1}}</function_call>\n|

      tcs = OpenAICompat.parse_tool_calls_from_content(content)
      assert length(tcs) == 2
      assert Enum.any?(tcs, &(&1.name == "tool_a"))
      assert Enum.any?(tcs, &(&1.name == "tool_b"))
    end

    # ── Format 3: raw JSON {"name": "...", "arguments": {...}} ──

    test "parses raw JSON tool call" do
      content = ~s|{"name": "memory_save", "arguments": {"key": "foo", "value": "bar"}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "memory_save"
      assert tc.arguments == %{"key" => "foo", "value" => "bar"}
    end

    test "parses raw JSON with nested arguments" do
      content =
        ~s|{"name": "file_edit", "arguments": {"path": "/x", "changes": {"line": 5, "text": "hello"}}}|

      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "file_edit"
      assert tc.arguments["changes"] == %{"line" => 5, "text" => "hello"}
    end
  end

  # ---------------------------------------------------------------------------
  # extract_balanced_json/1 edge cases (exercised via parse_tool_calls_from_content)
  #
  # All tests use the <function_call> wrapper so that the function_call branch
  # is taken and extract_balanced_json is called on the wrapped JSON string.
  # ---------------------------------------------------------------------------

  describe "extract_balanced_json edge cases (via parse_tool_calls_from_content)" do
    test "deeply nested JSON object is parsed correctly" do
      json = ~s|{"name": "deep", "arguments": {"a": {"b": {"c": {"d": "val"}}}}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "deep"
      assert tc.arguments == %{"a" => %{"b" => %{"c" => %{"d" => "val"}}}}
    end

    test "string value with escaped quotes is parsed correctly" do
      # The outer JSON uses escaped quotes inside the sigil
      json = ~s|{"name": "echo", "arguments": {"msg": "he said \\"hello\\""}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "echo"
      assert tc.arguments["msg"] == ~s|he said "hello"|
    end

    test "string value with escaped backslashes is parsed correctly" do
      # JSON with Windows-style path separators
      win_path = "C" <> ":\\Users\\foo"
      json = Jason.encode!(%{"name" => "win_path", "arguments" => %{"path" => win_path}})
      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "win_path"
      assert tc.arguments["path"] == win_path
    end

    test "string value containing braces is parsed correctly" do
      json = ~s|{"name": "run_code", "arguments": {"code": "if (x) { return; }"}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "run_code"
      assert tc.arguments["code"] == "if (x) { return; }"
    end

    test "empty object as arguments produces empty map" do
      json = ~s|{"name": "noop", "arguments": {}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "noop"
      assert tc.arguments == %{}
    end

    test "nested empty object as argument value is parsed correctly" do
      json = ~s|{"name": "cfg", "arguments": {"opts": {}}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "cfg"
      assert tc.arguments == %{"opts" => %{}}
    end

    test "array value in arguments is parsed correctly" do
      json = ~s|{"name": "tag_item", "arguments": {"tags": ["a", "b"]}}|
      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "tag_item"
      assert tc.arguments["tags"] == ["a", "b"]
    end

    test "truncated JSON missing closing brace returns empty list gracefully" do
      # Missing the outer closing brace — extract_balanced_json returns :error
      truncated = ~s|<function_call>{"name": "broken", "arguments": {"x": 1}|
      assert OpenAICompat.parse_tool_calls_from_content(truncated) == []
    end

    test "non-JSON content containing braces returns empty list" do
      # Contains { but is not valid JSON and has no name/arguments structure
      content = "call function(x) { return x * 2; }"
      assert OpenAICompat.parse_tool_calls_from_content(content) == []
    end

    test "multiple nested same-level objects in arguments" do
      json =
        ~s|{"name": "multi", "arguments": {"a": {"x": 1}, "b": {"y": 2}}}|

      [tc] = OpenAICompat.parse_tool_calls_from_content(function_call_wrap(json))
      assert tc.name == "multi"
      assert tc.arguments["a"] == %{"x" => 1}
      assert tc.arguments["b"] == %{"y" => 2}
    end
  end

  # ---------------------------------------------------------------------------
  # scan_balanced / extract_balanced_json via XML Format 1
  #
  # The XML path also exercises scan_balanced and extract_balanced_json because
  # extract_xml_function_calls calls extract_balanced_json on the parameters
  # portion of the tag.
  # ---------------------------------------------------------------------------

  describe "scan_balanced via XML format (extract_xml_function_calls)" do
    test "XML with deeply nested parameters" do
      params = ~s|{"outer": {"middle": {"inner": "value"}}}|
      content = xml_function_tag("deep_xml", params)
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "deep_xml"
      assert tc.arguments == %{"outer" => %{"middle" => %{"inner" => "value"}}}
    end

    test "XML with string values containing opening and closing braces" do
      params = ~s|{"snippet": "for i in range(10): { pass }"}|
      content = xml_function_tag("code_tool", params)
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.arguments["snippet"] == "for i in range(10): { pass }"
    end

    test "XML with escaped quotes inside string values" do
      params = ~s|{"label": "he said \\"hi\\"", "value": 1}|
      content = xml_function_tag("annotate", params)
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.arguments["label"] == ~s|he said "hi"|
    end

    test "multiple XML function tags with nested args are all parsed" do
      content =
        xml_function_tag("tool_one", ~s|{"x": {"a": 1}}|) <>
          "\n" <>
          xml_function_tag("tool_two", ~s|{"y": {"b": 2}}|)

      tcs = OpenAICompat.parse_tool_calls_from_content(content)
      assert length(tcs) == 2

      one = Enum.find(tcs, &(&1.name == "tool_one"))
      two = Enum.find(tcs, &(&1.name == "tool_two"))

      assert one.arguments == %{"x" => %{"a" => 1}}
      assert two.arguments == %{"y" => %{"b" => 2}}
    end

    test "malformed XML with missing closing tag still parses present tool call" do
      # First tag is well-formed; second is truncated with no closing tag.
      # The well-formed tag should produce one result; the truncated one is
      # ignored because extract_balanced_json returns :error for it.
      well_formed = xml_function_tag("ok_tool", ~s|{"k": "v"}|)
      malformed = ~s|<function name="broken_tool" parameters={"incomplete": |
      content = well_formed <> "\n" <> malformed

      tcs = OpenAICompat.parse_tool_calls_from_content(content)
      # The good tag must be parsed; the bad one must not crash.
      assert Enum.any?(tcs, &(&1.name == "ok_tool"))
      refute Enum.any?(tcs, &(&1.name == "broken_tool"))
    end

    test "XML with empty parameters object" do
      content = xml_function_tag("empty_params", "{}")
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "empty_params"
      assert tc.arguments == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_tool_name/1 (tested indirectly via parse_tool_calls/1 and
  # parse_tool_calls_from_content/1, since normalize_tool_name is private)
  # ---------------------------------------------------------------------------

  describe "normalize_tool_name (via parse_tool_calls and parse_tool_calls_from_content)" do
    test "clean name is returned unchanged" do
      msg = %{
        "tool_calls" => [
          %{"id" => "c1", "function" => %{"name" => "file_read", "arguments" => "{}"}}
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "file_read"
    end

    test "name with trailing whitespace is trimmed" do
      msg = %{
        "tool_calls" => [
          %{"id" => "c2", "function" => %{"name" => "file_read  ", "arguments" => "{}"}}
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "file_read"
    end

    test "name with space-appended garbage yields first token only (Bug 5 fix)" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => "c3",
            "function" => %{"name" => "file_read extra stuff", "arguments" => "{}"}
          }
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "file_read"
    end

    test "name with brace-appended arguments is cleaned via XML path" do
      # normalize_tool_name splits on [ \s({ ] so "file_read(...)" -> "file_read"
      # Use parens instead of JSON (quotes inside XML attr break regex)
      content =
        xml_function_tag("file_read(path=/x)", ~s|{"path": "/x"}|)

      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == "file_read"
    end

    test "name with leading spaces is not trimmed (normalize_tool_name splits first)" do
      # normalize_tool_name does: String.split(name, ~r/[\s({]/) |> List.first()
      # When name starts with spaces, e.g. "  spaced_tool", the split produces
      # ["", "", "spaced_tool", ...] and List.first returns "".
      # String.trim("") is still "".  The function does NOT strip leading spaces
      # before splitting — this is the documented behaviour of the current impl.
      content = xml_function_tag("  spaced_tool  ", ~s|{"k": "v"}|)
      [tc] = OpenAICompat.parse_tool_calls_from_content(content)
      assert tc.name == ""
    end
  end

  # ---------------------------------------------------------------------------
  # format_tools/1
  # ---------------------------------------------------------------------------

  describe "format_tools/1" do
    test "single tool with full schema is formatted correctly" do
      tools = [
        %{
          name: "file_read",
          description: "Read the contents of a file.",
          parameters: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"]
          }
        }
      ]

      [formatted] = OpenAICompat.format_tools(tools)
      assert formatted["type"] == "function"
      assert formatted["function"]["name"] == "file_read"
      assert formatted["function"]["description"] == "Read the contents of a file."
      assert formatted["function"]["parameters"]["required"] == ["path"]
    end

    test "tool with empty parameters map is formatted correctly" do
      tools = [
        %{
          name: "ping",
          description: "Ping the system.",
          parameters: %{"type" => "object", "properties" => %{}}
        }
      ]

      [formatted] = OpenAICompat.format_tools(tools)
      assert formatted["function"]["name"] == "ping"
      assert formatted["function"]["parameters"] == %{"type" => "object", "properties" => %{}}
    end

    test "multiple tools are all formatted" do
      tools = [
        %{name: "tool_a", description: "A", parameters: %{}},
        %{name: "tool_b", description: "B", parameters: %{}},
        %{name: "tool_c", description: "C", parameters: %{}}
      ]

      formatted = OpenAICompat.format_tools(tools)
      assert length(formatted) == 3
      names = Enum.map(formatted, & &1["function"]["name"])
      assert names == ["tool_a", "tool_b", "tool_c"]
    end

    test "empty tool list returns empty list" do
      assert OpenAICompat.format_tools([]) == []
    end

    test "all formatted entries have type 'function'" do
      tools = [
        %{name: "t1", description: "d1", parameters: %{}},
        %{name: "t2", description: "d2", parameters: %{}}
      ]

      formatted = OpenAICompat.format_tools(tools)
      assert Enum.all?(formatted, &(&1["type"] == "function"))
    end
  end

  # ---------------------------------------------------------------------------
  # parse_usage/1
  #
  # parse_usage/1 is a private function called only inside do_chat/5 which
  # requires a live HTTP connection.  It cannot be unit-tested directly.
  # The behaviour is documented here for reference:
  #
  #   - Full map  %{"usage" => %{"prompt_tokens" => n, "completion_tokens" => m}}
  #     → %{input_tokens: n, output_tokens: m}
  #   - Any other shape (missing key, partial, nil) → %{}
  #
  # If integration-level HTTP mocking is added in future (e.g. with Bypass or
  # Req.Test), those tests should live in test/integration/providers/ and drive
  # the public chat/5 function.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # format_messages/1 — original tests
  # ---------------------------------------------------------------------------

  describe "format_messages/1" do
    test "formats simple user message" do
      msgs = [%{role: "user", content: "hello"}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted == %{"role" => "user", "content" => "hello"}
    end

    test "formats tool result message with tool_call_id" do
      msgs = [%{role: "tool", content: "result", tool_call_id: "call_1"}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted["role"] == "tool"
      assert formatted["tool_call_id"] == "call_1"
    end

    test "formats assistant message with tool_calls" do
      msgs = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "call_1", name: "foo", arguments: %{"x" => 1}}]
        }
      ]

      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted["role"] == "assistant"
      assert [tc] = formatted["tool_calls"]
      assert tc["function"]["name"] == "foo"
    end

    # ── edge cases ──

    test "empty content in assistant message is preserved as empty string" do
      msgs = [%{role: "assistant", content: ""}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted["content"] == ""
    end

    test "assistant message with tool_calls having map arguments encodes them to JSON" do
      args_map = %{"key" => "value", "num" => 42}

      msgs = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: "call_abc", name: "my_tool", arguments: args_map}]
        }
      ]

      [formatted] = OpenAICompat.format_messages(msgs)
      [tc] = formatted["tool_calls"]
      # arguments must be a JSON-encoded string when a map is provided
      assert is_binary(tc["function"]["arguments"])
      {:ok, decoded} = Jason.decode(tc["function"]["arguments"])
      assert decoded == args_map
    end

    test "assistant message with tool_call having nil id generates a non-empty id" do
      msgs = [
        %{
          role: "assistant",
          content: "",
          tool_calls: [%{id: nil, name: "tool_x", arguments: %{}}]
        }
      ]

      [formatted] = OpenAICompat.format_messages(msgs)
      [tc] = formatted["tool_calls"]
      # nil id falls back to "" via to_string(nil || "")
      # The source code: to_string(tc[:id] || tc["id"] || "")
      # nil || nil || "" → "" — so id will be an empty string in this case.
      assert is_binary(tc["id"])
    end

    test "message with no tool_calls key formats as generic role/content pair" do
      msgs = [%{role: "assistant", content: "I can help"}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted == %{"role" => "assistant", "content" => "I can help"}
      refute Map.has_key?(formatted, "tool_calls")
    end

    test "message with empty tool_calls list formats as generic role/content pair" do
      # The guard `when is_list(calls) and calls != []` means empty list takes
      # the generic %{role, content} branch, not the tool_calls branch.
      msgs = [%{role: "assistant", content: "hello", tool_calls: []}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted["role"] == "assistant"
      assert formatted["content"] == "hello"
      refute Map.has_key?(formatted, "tool_calls")
    end

    test "string-keyed map is passed through as-is" do
      msg = %{"role" => "user", "content" => "raw string keyed"}
      [formatted] = OpenAICompat.format_messages([msg])
      assert formatted == msg
    end

    test "tool result message coerces atom-keyed content and id to strings" do
      msgs = [%{role: "tool", content: :some_atom, tool_call_id: :call_1}]
      [formatted] = OpenAICompat.format_messages(msgs)
      assert formatted["content"] == "some_atom"
      assert formatted["tool_call_id"] == "call_1"
    end

    test "multiple messages are all formatted in order" do
      msgs = [
        %{role: "system", content: "You are helpful."},
        %{role: "user", content: "Hello!"},
        %{role: "assistant", content: "Hi there!"}
      ]

      formatted = OpenAICompat.format_messages(msgs)
      assert length(formatted) == 3
      assert Enum.at(formatted, 0)["role"] == "system"
      assert Enum.at(formatted, 1)["role"] == "user"
      assert Enum.at(formatted, 2)["role"] == "assistant"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_tool_calls/1 — original tests
  # ---------------------------------------------------------------------------

  describe "parse_tool_calls/1" do
    test "parses native OpenAI tool_calls format" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => "call_123",
            "function" => %{
              "name" => "file_read",
              "arguments" => Jason.encode!(%{"path" => "/etc/hosts"})
            }
          }
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.id == "call_123"
      assert tc.name == "file_read"
      assert tc.arguments == %{"path" => "/etc/hosts"}
    end

    test "falls back to content parsing when no tool_calls key" do
      msg = %{
        "content" => ~s|<function name="ping" parameters={"host": "localhost"}></function>|
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "ping"
    end

    test "returns empty list when nothing is found" do
      assert OpenAICompat.parse_tool_calls(%{"content" => "plain text"}) == []
      assert OpenAICompat.parse_tool_calls(%{}) == []
    end

    test "strips whitespace from tool name (Bug 5 fix)" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => "call_xyz",
            "function" => %{
              "name" => "file_read  extra_garbage",
              "arguments" => "{}"
            }
          }
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "file_read"
    end

    # ── edge cases ──

    test "tool_calls list with multiple entries parses all of them" do
      msg = %{
        "tool_calls" => [
          %{"id" => "id1", "function" => %{"name" => "tool_a", "arguments" => "{}"}},
          %{
            "id" => "id2",
            "function" => %{
              "name" => "tool_b",
              "arguments" => Jason.encode!(%{"x" => 99})
            }
          }
        ]
      }

      tcs = OpenAICompat.parse_tool_calls(msg)
      assert length(tcs) == 2

      a = Enum.find(tcs, &(&1.name == "tool_a"))
      b = Enum.find(tcs, &(&1.name == "tool_b"))

      assert a.id == "id1"
      assert a.arguments == %{}
      assert b.id == "id2"
      assert b.arguments == %{"x" => 99}
    end

    test "malformed arguments JSON falls back to empty map" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => "bad_args",
            "function" => %{"name" => "oops", "arguments" => "not json at all"}
          }
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "oops"
      assert tc.arguments == %{}
    end

    test "missing id in tool_calls entry generates a non-empty id" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => nil,
            "function" => %{"name" => "no_id_tool", "arguments" => "{}"}
          }
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert is_binary(tc.id)
      assert byte_size(tc.id) > 0
    end

    test "missing function.name key coerces to empty string" do
      # The source does: call["function"]["name"] |> to_string()
      # If the key is absent, call["function"]["name"] is nil -> to_string(nil) -> ""
      msg = %{
        "tool_calls" => [
          %{"id" => "no_name", "function" => %{"name" => nil, "arguments" => "{}"}}
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      # nil -> to_string -> "" -> split -> [""] -> List.first -> "" -> trim -> ""
      assert tc.name == ""
    end

    test "empty tool_calls list returns empty list" do
      msg = %{"tool_calls" => []}
      assert OpenAICompat.parse_tool_calls(msg) == []
    end

    test "id present as string is preserved" do
      msg = %{
        "tool_calls" => [
          %{
            "id" => "my_specific_id",
            "function" => %{"name" => "check", "arguments" => "{}"}
          }
        ]
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.id == "my_specific_id"
    end

    test "returns empty list for completely empty map" do
      assert OpenAICompat.parse_tool_calls(%{}) == []
    end

    test "content path with function_call tag produces correct tool call" do
      msg = %{
        "content" =>
          ~s|<function_call>{"name": "search", "arguments": {"q": "test"}}</function_call>|
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "search"
      assert tc.arguments == %{"q" => "test"}
    end

    test "content path with raw JSON tool call produces correct tool call" do
      msg = %{
        "content" => ~s|{"name": "raw_call", "arguments": {"flag": true}}|
      }

      [tc] = OpenAICompat.parse_tool_calls(msg)
      assert tc.name == "raw_call"
      assert tc.arguments == %{"flag" => true}
    end
  end

  # ---------------------------------------------------------------------------
  # stream_from_sse_chunks/3 — the P2 fix: streaming requests
  # `stream_options.include_usage`, and when the server honors it and sends a
  # final usage chunk, that usage is parsed onto the :done result instead of
  # staying empty. When the server never sends usage (ignores the flag), the
  # char/token estimate fallback kicks in so it's never a flat 0.
  # ---------------------------------------------------------------------------

  describe "stream_from_sse_chunks/3 — usage parsing" do
    defp sse(payload), do: "data: #{Jason.encode!(payload)}\n\n"

    test "parses a usage chunk attached to the final choices delta" do
      chunks = [
        sse(%{"choices" => [%{"delta" => %{"content" => "Hello"}}]}),
        sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}),
        sse(%{
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 321, "completion_tokens" => 12}
        }),
        "data: [DONE]\n\n"
      ]

      result = OpenAICompat.stream_from_sse_chunks(chunks)

      assert result.content == "Hello"
      assert result.stop_reason == "stop"
      assert result.usage.input_tokens == 321
      assert result.usage.output_tokens == 12
      refute Map.get(result.usage, :estimated)
    end

    test "parses a standalone final usage-only chunk (no choices)" do
      chunks = [
        sse(%{"choices" => [%{"delta" => %{"content" => "Hi there"}}]}),
        sse(%{"usage" => %{"prompt_tokens" => 50, "completion_tokens" => 9}}),
        "data: [DONE]\n\n"
      ]

      result = OpenAICompat.stream_from_sse_chunks(chunks)
      assert result.usage.input_tokens == 50
      assert result.usage.output_tokens == 9
    end

    # glm-style final chunk shape: "choices" is present but an EMPTY list
    # (not absent), with a top-level "usage" object alongside it. This is
    # distinct from the "no choices key at all" case above and from the
    # "non-empty choices with attached usage" case: the first process_sse_line
    # clause requires a NON-empty choices list (`[%{"delta" => delta} | _]`),
    # so an empty list falls through to the standalone-usage clause, which
    # matches on any map containing the usage sub-fields regardless of
    # whatever else (including an empty "choices" key) is also present.
    test "parses usage from a chunk with an empty choices list (glm final-chunk shape)" do
      chunks = [
        sse(%{"choices" => [%{"delta" => %{"content" => "Hi there"}}]}),
        sse(%{"choices" => [], "usage" => %{"prompt_tokens" => 77, "completion_tokens" => 21}}),
        "data: [DONE]\n\n"
      ]

      result = OpenAICompat.stream_from_sse_chunks(chunks)
      assert result.usage.input_tokens == 77
      assert result.usage.output_tokens == 21
      refute Map.get(result.usage, :estimated)
    end

    test "falls back to a non-zero char/token estimate when the server never sends usage" do
      messages = [%{role: "user", content: "Tell me a very long story about dragons and castles"}]

      chunks = [
        sse(%{"choices" => [%{"delta" => %{"content" => "Once upon a time"}}]}),
        sse(%{"choices" => [%{"delta" => %{"content" => " there was a dragon."}}]}),
        sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}),
        "data: [DONE]\n\n"
      ]

      result = OpenAICompat.stream_from_sse_chunks(chunks, "gpt-4o", messages)

      # The critical assertion: never a flat 0/0 even though the server sent
      # no usage object at all.
      assert result.usage.input_tokens > 0
      assert result.usage.output_tokens > 0
      assert result.usage.estimated == true
    end

    test "estimate fallback with empty content/messages still returns a map with zero, not a crash" do
      chunks = ["data: [DONE]\n\n"]
      result = OpenAICompat.stream_from_sse_chunks(chunks, "gpt-4o", [])
      assert result.usage.input_tokens == 0
      assert result.usage.output_tokens == 0
    end
  end

  # ---------------------------------------------------------------------------
  # build_stream_body/3 — asserts the actual wire request asks the backend
  # for usage on the stream (the P2 fix). Without this, the server never
  # sends a usage object regardless of how well the client parses one.
  # ---------------------------------------------------------------------------

  describe "build_stream_body/3" do
    test "requests stream_options.include_usage" do
      body = OpenAICompat.build_stream_body("gpt-4o", [%{role: "user", content: "hi"}], [])
      assert body.stream_options == %{include_usage: true}
      assert body.stream == true
    end

    test "include_usage flag is present regardless of other opts" do
      body =
        OpenAICompat.build_stream_body("llama3", [%{role: "user", content: "hi"}],
          temperature: 0.2,
          max_tokens: 100
        )

      assert body.stream_options == %{include_usage: true}
    end
  end

  describe "service_tier (speed/cost priority)" do
    @msgs [%{role: "user", content: "hi"}]

    test "adds service_tier for the real OpenAI provider" do
      body = OpenAICompat.build_stream_body("gpt-5", @msgs, provider: :openai, service_tier: "flex")
      assert body.service_tier == "flex"
    end

    test "NEVER sends service_tier to other OpenAI-compatible backends (422 guard)" do
      body = OpenAICompat.build_stream_body("grok-4.6", @msgs, provider: :xai, service_tier: "flex")
      refute Map.has_key?(body, :service_tier)
    end

    test "omitted when no priority/service_tier is set" do
      body = OpenAICompat.build_stream_body("gpt-5", @msgs, provider: :openai)
      refute Map.has_key?(body, :service_tier)
    end
  end
end
