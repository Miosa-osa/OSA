defmodule OptimalSystemAgent.Tools.Builtins.UseToolTest do
  @moduledoc """
  Tests for `use_tool`, the meta-dispatch half of tool virtualization
  (steal-list 11g).

  Verifies the full discover-then-dispatch flow:

    * `tool_search`/`Registry.search` RANKS a relevant deferred MCP tool.
    * `use_tool` DISPATCHES a discovered qualified `mcp__server__tool` and
      normalizes its result — through both the handler directly and the
      authoritative `Registry.execute/2` agent-loop path.
    * Corrective errors steer the model: meta-tools, already-active tools, and
      unknown names are refused with actionable guidance.
    * Input validation rejects malformed calls.
  """
  # async: false — swaps the global {Registry, :mcp_tools} persistent_term and
  # the :mcp_server_session app env.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.ToolBridge
  alias OptimalSystemAgent.Tools.Builtins.UseTool
  alias OptimalSystemAgent.Tools.{Registry, UseContext}

  @pt_key {OptimalSystemAgent.Tools.Registry, :mcp_tools}

  defmodule CannedSession do
    @moduledoc false
    def call_tool(_server, "notion_search", args),
      do: {:ok, %{"content" => [%{"type" => "text", "text" => "found: #{args["query"] || ""}"}]}}

    def call_tool(_server, "boom", _args),
      do: {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => "kaboom"}]}}
  end

  setup do
    prev_session = Application.get_env(:optimal_system_agent, :mcp_server_session)
    prev_tools = :persistent_term.get(@pt_key, %{})

    Application.put_env(:optimal_system_agent, :mcp_server_session, CannedSession)

    # A deferred (virtualized) MCP toolset: present in the full listing, absent
    # from the base toolbox — exactly what use_tool exists to reach.
    entries =
      ToolBridge.build_tools("notion", [
        %{
          "name" => "notion_search",
          "description" => "Search Notion pages and databases by keyword query",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}}
          }
        },
        %{"name" => "boom", "description" => "always errors", "inputSchema" => %{}}
      ])

    :persistent_term.put(@pt_key, Map.merge(prev_tools, entries))

    on_exit(fn ->
      if prev_session,
        do: Application.put_env(:optimal_system_agent, :mcp_server_session, prev_session),
        else: Application.delete_env(:optimal_system_agent, :mcp_server_session)

      :persistent_term.put(@pt_key, prev_tools)
    end)

    :ok
  end

  # ── Discovery: search ranks the relevant deferred tool ────────────────

  describe "discovery via Registry.search/2 (tool_search backend)" do
    test "ranks the relevant MCP tool for a keyword query" do
      names = Registry.search("notion search", limit: 5) |> Enum.map(& &1.name)
      assert "mcp__notion__notion_search" in names
    end

    test "the deferred MCP tool is discoverable but NOT in the base toolbox" do
      # Deferred → absent from the model's default tool list ...
      refute "mcp__notion__notion_search" in (Registry.list_active() |> Enum.map(& &1.name))
      # ... but present in the full (deferred-inclusive) listing.
      assert "mcp__notion__notion_search" in (Registry.list_tools_direct() |> Enum.map(& &1.name))
    end
  end

  # ── Dispatch ──────────────────────────────────────────────────────────

  describe "dispatch" do
    test "invokes a discovered qualified tool and normalizes its result" do
      assert {:ok, "found: roadmap"} =
               UseTool.Handler.execute(
                 %{"tool_name" => "mcp__notion__notion_search", "tool_input" => %{"query" => "roadmap"}},
                 UseContext.empty()
               )
    end

    test "works through the authoritative Registry.execute/2 agent-loop path" do
      assert {:ok, "found: q2"} =
               Registry.execute("use_tool", %{
                 "tool_name" => "mcp__notion__notion_search",
                 "tool_input" => %{"query" => "q2"}
               })
    end

    test "propagates a dispatched-tool error" do
      assert {:error, msg} =
               UseTool.Handler.execute(
                 %{"tool_name" => "mcp__notion__boom", "tool_input" => %{}},
                 UseContext.empty()
               )

      assert msg =~ "kaboom"
    end

    test "decodes a JSON-string tool_input" do
      assert {:ok, "found: encoded"} =
               UseTool.Handler.execute(
                 %{
                   "tool_name" => "mcp__notion__notion_search",
                   "tool_input" => ~S({"query":"encoded"})
                 },
                 UseContext.empty()
               )
    end
  end

  # ── Corrective errors ─────────────────────────────────────────────────

  describe "corrective errors" do
    test "refuses to dispatch a meta-tool" do
      assert {:error, msg} =
               UseTool.Handler.execute(
                 %{"tool_name" => "tool_search", "tool_input" => %{"query" => "x"}},
                 UseContext.empty()
               )

      assert msg =~ "meta-tool"
    end

    test "refuses to dispatch itself" do
      assert {:error, _} =
               UseTool.Handler.execute(
                 %{"tool_name" => "use_tool", "tool_input" => %{}},
                 UseContext.empty()
               )
    end

    test "steers the model to call an already-active tool directly" do
      # file_read is a normal builtin: active and directly callable.
      assert {:error, msg} =
               UseTool.Handler.execute(
                 %{"tool_name" => "file_read", "tool_input" => %{}},
                 UseContext.empty()
               )

      assert msg =~ "directly"
    end

    test "steers the model back to tool_search for an unknown name" do
      assert {:error, msg} =
               UseTool.Handler.execute(
                 %{"tool_name" => "mcp__notion__does_not_exist", "tool_input" => %{}},
                 UseContext.empty()
               )

      assert msg =~ "tool_search"
    end
  end

  # ── Validation ────────────────────────────────────────────────────────

  describe "validation" do
    test "requires tool_name" do
      assert {:error, _msg, -32_602} = UseTool.Handler.validate(%{}, UseContext.empty())
    end

    test "rejects a non-string tool_name" do
      assert {:error, _msg, -32_602} =
               UseTool.Handler.validate(%{"tool_name" => 42}, UseContext.empty())
    end

    test "rejects a non-object tool_input" do
      assert {:error, _msg, -32_602} =
               UseTool.Handler.validate(
                 %{"tool_name" => "mcp__notion__notion_search", "tool_input" => 5},
                 UseContext.empty()
               )
    end

    test "defaults a missing tool_input to an empty object" do
      assert {:ok, %{"tool_input" => %{}}} =
               UseTool.Handler.validate(
                 %{"tool_name" => "mcp__notion__notion_search"},
                 UseContext.empty()
               )
    end
  end

  # ── Loading semantics ─────────────────────────────────────────────────

  describe "loading semantics" do
    test "use_tool is registered and never itself deferred-hidden when virtualization is active" do
      # With mode :on, any MCP tool makes virtualization active → use_tool present.
      prev = Application.get_env(:optimal_system_agent, :mcp_virtualization)
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :on)

      try do
        refute UseTool.Tool.should_defer?()
      after
        if prev,
          do: Application.put_env(:optimal_system_agent, :mcp_virtualization, prev),
          else: Application.delete_env(:optimal_system_agent, :mcp_virtualization)
      end
    end

    test "use_tool defers (hides) itself when virtualization is off (small-toolset path unchanged)" do
      prev = Application.get_env(:optimal_system_agent, :mcp_virtualization)
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :off)

      try do
        assert UseTool.Tool.should_defer?()
      after
        if prev,
          do: Application.put_env(:optimal_system_agent, :mcp_virtualization, prev),
          else: Application.delete_env(:optimal_system_agent, :mcp_virtualization)
      end
    end
  end
end
