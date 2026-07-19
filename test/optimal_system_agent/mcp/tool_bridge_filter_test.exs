defmodule OptimalSystemAgent.MCP.ToolBridgeFilterTest do
  @moduledoc """
  Unit tests for the `tool_filter` allowlist enforcement in
  `ToolBridge.build_tools/3`. A configured allowlist must trim discovered tools
  to the listed names; a `nil` filter exposes everything; an explicit empty
  allowlist exposes nothing (fail-closed).
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.MCP.Client.ToolBridge

  @schemas [
    %{"name" => "safe_read", "description" => "reads", "inputSchema" => %{}},
    %{"name" => "dangerous_write", "description" => "writes", "inputSchema" => %{}}
  ]

  test "nil tool_filter exposes every discovered tool" do
    tools = ToolBridge.build_tools("srv", @schemas, nil)
    assert Map.has_key?(tools, "mcp__srv__safe_read")
    assert Map.has_key?(tools, "mcp__srv__dangerous_write")
  end

  test "two-arg build_tools (no filter) exposes every tool" do
    tools = ToolBridge.build_tools("srv", @schemas)
    assert map_size(tools) == 2
  end

  test "an allowlist keeps only listed tools" do
    tools = ToolBridge.build_tools("srv", @schemas, ["safe_read"])
    assert Map.has_key?(tools, "mcp__srv__safe_read")
    refute Map.has_key?(tools, "mcp__srv__dangerous_write")
    assert map_size(tools) == 1
  end

  test "an empty allowlist exposes no tools (fail-closed)" do
    assert ToolBridge.build_tools("srv", @schemas, []) == %{}
  end

  test "allowlist entries that match nothing simply yield an empty map" do
    assert ToolBridge.build_tools("srv", @schemas, ["nonexistent"]) == %{}
  end
end
