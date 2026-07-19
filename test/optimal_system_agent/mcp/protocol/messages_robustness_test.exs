defmodule OptimalSystemAgent.MCP.Protocol.MessagesRobustnessTest do
  @moduledoc """
  Covers the P2 MCP-robustness additions to the message layer: cursor-carrying
  `tools/list`, progress-token injection on `tools/call`, `nextCursor`
  extraction, and schema-tolerant tool sanitization.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Protocol.Messages

  describe "list_tools/2 pagination cursor" do
    test "omits params on the first page" do
      msg = Messages.list_tools(nil, nil)
      assert msg["method"] == "tools/list"
      assert msg["params"] == %{}
    end

    test "echoes a non-empty cursor to fetch the next page" do
      msg = Messages.list_tools(nil, "abc123")
      assert msg["params"] == %{"cursor" => "abc123"}
    end

    test "treats an empty cursor as the first page" do
      assert Messages.list_tools(nil, "")["params"] == %{}
    end
  end

  describe "next_cursor/1" do
    test "returns a present, non-empty cursor" do
      assert Messages.next_cursor(%{"nextCursor" => "c2"}) == "c2"
    end

    test "returns nil when absent or empty" do
      assert Messages.next_cursor(%{}) == nil
      assert Messages.next_cursor(%{"nextCursor" => ""}) == nil
    end
  end

  describe "call_tool/4 progress token" do
    test "attaches a _meta.progressToken when given" do
      msg = Messages.call_tool("do", %{"x" => 1}, nil, 99)
      assert get_in(msg, ["params", "_meta", "progressToken"]) == 99
      assert get_in(msg, ["params", "name"]) == "do"
    end

    test "omits _meta when no token is supplied" do
      msg = Messages.call_tool("do", %{}, nil, nil)
      refute Map.has_key?(msg["params"], "_meta")
    end
  end

  describe "parse_tool_list/1 schema tolerance" do
    test "keeps a tool with a valid outputSchema" do
      tools = [%{"name" => "t", "outputSchema" => %{"type" => "object"}}]
      assert [%{"name" => "t", "outputSchema" => %{"type" => "object"}}] =
               Messages.parse_tool_list(%{"tools" => tools})
    end

    test "strips a broken ($ref) outputSchema but keeps the tool" do
      tools = [%{"name" => "t", "inputSchema" => %{}, "outputSchema" => %{"$ref" => "#/x"}}]
      assert [tool] = Messages.parse_tool_list(%{"tools" => tools})
      assert tool["name"] == "t"
      refute Map.has_key?(tool, "outputSchema")
      # inputSchema is preserved untouched.
      assert tool["inputSchema"] == %{}
    end

    test "strips a non-object outputSchema" do
      tools = [%{"name" => "t", "outputSchema" => "nope"}]
      assert [tool] = Messages.parse_tool_list(%{"tools" => tools})
      refute Map.has_key?(tool, "outputSchema")
    end

    test "drops non-map entries and returns [] on a malformed result" do
      assert Messages.parse_tool_list(%{"tools" => ["junk", %{"name" => "ok"}]}) ==
               [%{"name" => "ok"}]

      assert Messages.parse_tool_list(%{}) == []
    end
  end
end
