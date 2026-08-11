defmodule OptimalSystemAgent.Security.MCPToolKeyCollisionTest do
  @moduledoc """
  `mcp__<server>__<tool>` is not injective when the server segment may itself
  contain `__`: server `a__b` + tool `c` and server `a` + tool `b__c` collide.
  `MCP.Config.sanitize_name/1` collapses `[^a-z0-9_]+` to `_`, so a configured
  server named `a_-b` becomes `a__b` — the collision is reachable from config.

  Consequences:

    * `parse_key/1` splits on the FIRST `__`, so a tool belonging to `a__b`
      routes to server `a`.
    * `Permissions.mcp_server_rule_matches?/2` parses the same key, so a rule
      scoped to server `a` grants a tool owned by `a__b`.
    * `build_tools/3`'s `Map.new/1` and `Manager`'s `Map.merge/2` resolve the
      collision last-write-wins, silently.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.ToolBridge
  alias OptimalSystemAgent.MCP.Config
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Settings

  describe "tool_key/2 injectivity" do
    test "a server segment containing __ has no unambiguous key and is rejected" do
      # `mcp__a__b__c` is BOTH tool_key("a__b", "c") and tool_key("a", "b__c").
      # There is no correct reading, so such a server segment is not valid.
      refute ToolBridge.valid_server_segment?("a__b")
      refute ToolBridge.valid_server_segment?("a__b__c")
      refute ToolBridge.valid_server_segment?("")
      refute ToolBridge.valid_server_segment?(nil)
    end

    test "every VALID server segment round-trips exactly" do
      for {server, tool} <- [
            {"a", "b__c"},
            {"srv", "tool"},
            {"a_b", "c_d"},
            {"a", "b"}
          ] do
        assert ToolBridge.valid_server_segment?(server)
        key = ToolBridge.tool_key(server, tool)

        assert ToolBridge.parse_key(key) == {:ok, {server, tool}},
               "#{inspect(key)} did not round-trip to #{inspect({server, tool})}"
      end
    end

    test "a server whose segment is ambiguous exposes no tools at all" do
      schemas = [%{"name" => "exfiltrate", "inputSchema" => %{"type" => "object"}}]
      assert ToolBridge.build_tools("a__b", schemas, nil) == %{}
    end
  end

  describe "sanitize_name/1 closes the reachability" do
    test "a configured name can no longer sanitize into a segment containing __" do
      assert Config.sanitize_name("a_-b") == "a_b"
      assert Config.sanitize_name("a - b") == "a_b"
      assert Config.sanitize_name("a__b") == "a_b"
      assert Config.sanitize_name("A.B-C") == "a_b_c"
    end

    test "every sanitized name is a valid, unambiguous server segment" do
      for raw <- ["a_-b", "a__b", "My Server!!", "x---y", "a.b.c", "srv"] do
        sanitized = Config.sanitize_name(raw)

        assert ToolBridge.valid_server_segment?(sanitized),
               "#{inspect(raw)} → #{inspect(sanitized)}"
      end
    end
  end

  describe "build_tools/3 fails closed on a residual collision" do
    test "two tools whose keys collide do not silently overwrite each other" do
      schemas = [
        %{"name" => "dup", "description" => "one", "inputSchema" => %{"type" => "object"}},
        %{"name" => "dup", "description" => "two", "inputSchema" => %{"type" => "object"}}
      ]

      built = ToolBridge.build_tools("srv", schemas, nil)

      # A duplicate tool name is ambiguous: it must be dropped, not resolved
      # last-write-wins into a single entry the operator never saw.
      assert built == %{}
    end

    test "distinct tools from one server are all registered" do
      schemas = [
        %{"name" => "alpha", "description" => "a", "inputSchema" => %{"type" => "object"}},
        %{"name" => "beta", "description" => "b", "inputSchema" => %{"type" => "object"}}
      ]

      built = ToolBridge.build_tools("srv", schemas, nil)
      assert map_size(built) == 2
    end
  end

  describe "permission scoping is not confusable across servers" do
    @flag_file Path.join(System.tmp_dir!(), "osa-mcp-collision-settings.json")

    setup do
      prior = Application.get_env(:optimal_system_agent, :settings_flag_path)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
          p -> Application.put_env(:optimal_system_agent, :settings_flag_path, p)
        end

        File.rm(@flag_file)
        Settings.reset_cache()
      end)

      File.write!(
        @flag_file,
        Jason.encode!(%{"permissions" => %{"allow" => ["mcp__a"]}})
      )

      Application.put_env(:optimal_system_agent, :settings_flag_path, @flag_file)
      Settings.reset_cache()
      :ok
    end

    test "an allow for server `a` covers a's own tools" do
      assert Permissions.check(ToolBridge.tool_key("a", "read"), %{}) == :allow
    end

    test "an allow for server `a` does not reach any other server" do
      assert Permissions.check(ToolBridge.tool_key("ab", "read"), %{}) == :ask
      assert Permissions.check(ToolBridge.tool_key("a_b", "read"), %{}) == :ask
      assert Permissions.check(ToolBridge.tool_key("b", "read"), %{}) == :ask
    end

    test "the key that used to be confusable is attributed to exactly one server" do
      # `mcp__a__b__c` parses as server `a`, tool `b__c` — and that is now the
      # ONLY server that can ever own it, because `a__b` cannot be registered.
      assert ToolBridge.parse_key("mcp__a__b__c") == {:ok, {"a", "b__c"}}
      assert ToolBridge.build_tools("a__b", [%{"name" => "c"}], nil) == %{}
    end
  end
end
