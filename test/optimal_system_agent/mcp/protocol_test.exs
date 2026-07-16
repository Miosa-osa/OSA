defmodule OptimalSystemAgent.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Protocol.{JSONRPC, Messages}

  describe "JSONRPC round-trip" do
    test "request encodes and decodes back to the same method/params" do
      req = JSONRPC.request("tools/call", %{"name" => "echo", "arguments" => %{"x" => 1}})
      assert req["jsonrpc"] == "2.0"
      assert is_integer(req["id"])

      {:ok, json} = JSONRPC.encode(req)
      assert {:ok, {:request, id, "tools/call", params}} = JSONRPC.decode(json)
      assert id == req["id"]
      assert params["name"] == "echo"
      assert params["arguments"] == %{"x" => 1}
    end

    test "notification has no id and decodes as :notification" do
      notif = JSONRPC.notification("notifications/initialized", %{})
      refute Map.has_key?(notif, "id")

      {:ok, json} = JSONRPC.encode(notif)
      assert {:ok, {:notification, "notifications/initialized", %{}}} = JSONRPC.decode(json)
    end

    test "response round-trips" do
      resp = JSONRPC.response(7, %{"ok" => true})
      {:ok, json} = JSONRPC.encode(resp)
      assert {:ok, {:response, 7, %{"ok" => true}}} = JSONRPC.decode(json)
    end

    test "error response round-trips and normalizes" do
      err = JSONRPC.error_response(9, -32601, "Method not found")
      {:ok, json} = JSONRPC.encode(err)
      assert {:ok, {:error, 9, %{code: -32601, message: "Method not found"}}} = JSONRPC.decode(json)
    end

    test "monotonic ids are unique and increasing" do
      a = JSONRPC.next_id()
      b = JSONRPC.next_id()
      assert b > a
    end

    test "invalid json is reported as an error" do
      assert {:error, {:invalid_json, _}} = JSONRPC.decode("{not json")
    end
  end

  describe "MCP message builders" do
    test "initialize carries protocolVersion and clientInfo" do
      msg = Messages.initialize()
      assert msg["method"] == "initialize"
      assert msg["params"]["protocolVersion"]
      assert msg["params"]["clientInfo"]["name"] == "osa"
    end

    test "call_tool builds tools/call with name + arguments" do
      msg = Messages.call_tool("search", %{"q" => "hi"})
      assert msg["method"] == "tools/call"
      assert msg["params"]["name"] == "search"
      assert msg["params"]["arguments"] == %{"q" => "hi"}
    end

    test "parse_tool_list extracts tools array" do
      assert [%{"name" => "a"}] = Messages.parse_tool_list(%{"tools" => [%{"name" => "a"}]})
      assert [] = Messages.parse_tool_list(%{})
    end
  end

  describe "normalize_tool_result → OSA shape" do
    test "text content becomes {:ok, binary}" do
      result = %{"content" => [%{"type" => "text", "text" => "hello"}]}
      assert {:ok, "hello"} = Messages.normalize_tool_result(result)
    end

    test "multiple text blocks are joined with newlines" do
      result = %{
        "content" => [
          %{"type" => "text", "text" => "line1"},
          %{"type" => "text", "text" => "line2"}
        ]
      }

      assert {:ok, "line1\nline2"} = Messages.normalize_tool_result(result)
    end

    test "isError becomes {:error, text}" do
      result = %{"isError" => true, "content" => [%{"type" => "text", "text" => "boom"}]}
      assert {:error, "boom"} = Messages.normalize_tool_result(result)
    end

    test "single image becomes {:ok, {:image, ...}}" do
      result = %{
        "content" => [%{"type" => "image", "data" => "BASE64", "mimeType" => "image/png"}]
      }

      assert {:ok, {:image, %{media_type: "image/png", data: "BASE64", path: "mcp-image"}}} =
               Messages.normalize_tool_result(result)
    end

    test "resource block is rendered as text" do
      result = %{
        "content" => [%{"type" => "resource", "resource" => %{"uri" => "file:///x"}}]
      }

      assert {:ok, "[resource: file:///x]"} = Messages.normalize_tool_result(result)
    end
  end
end
