defmodule OptimalSystemAgent.Tools.McpVisibilityTest do
  @moduledoc """
  MCP tools must be DISCOVERABLE, not merely registered.

  Above `MCP.Virtualization`'s threshold (default 10) every MCP tool is stamped
  `should_defer?: true` and dropped from `Registry.list_active/0` — i.e. from
  the provider `tools` array. Before this change nothing put them back:
  `Soul.ToolsSection` read only `{Registry, :builtin_tools}`, so the servers
  appeared in neither the loaded schemas nor the deferred `<system-reminder>`
  name list. A configured MCP server left ZERO trace anywhere the model could
  see it, and an agent cannot use what it has no evidence exists.

  The measurement each test states explicitly is: how many of the N MCP tools
  and S servers are NAMEABLE by the model from the prompt alone.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul.ToolsSection
  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.Handler, as: ToolSearch
  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.UseContext

  @pt_key {Registry, :mcp_tools}

  # Distinctive text of the catalog BLOCK itself. The literal "<mcp-servers>"
  # is not usable as a marker: `tool_search`'s own description now names the
  # block (that is the point — it used to point the model at
  # <system-reminder>, where MCP tools have never appeared), so the tag string
  # is present in the prompt whether or not a server is connected.
  @catalog_marker "connected server(s) are available but NOT loaded"

  # 3 servers x 10 tools = 30 — comfortably over the virtualization threshold,
  # so every entry is deferred, which is exactly the invisible case.
  @servers ~w(gmail calendar drive)
  @tools_per_server 10

  setup do
    previous = :persistent_term.get(@pt_key, %{})

    aggregate =
      for server <- @servers, i <- 1..@tools_per_server, into: %{} do
        tool = "#{server}_action_#{i}"

        {"mcp__#{server}__#{tool}",
         %{
           original_name: tool,
           description: "Does #{tool} on the #{server} server",
           input_schema: %{
             "type" => "object",
             "properties" => %{"q" => %{"type" => "string", "description" => "query"}},
             "required" => ["q"]
           },
           should_defer?: true
         }}
      end

    :persistent_term.put(@pt_key, aggregate)
    on_exit(fn -> :persistent_term.put(@pt_key, previous) end)

    {:ok, aggregate: aggregate, total: map_size(aggregate)}
  end

  defp ctx, do: %UseContext{session_id: "mcp-visibility", permission_tier: :full}

  describe "the system prompt names every MCP server and tool" do
    test "all 3 servers and all 30 tools are nameable from the prompt", %{
      aggregate: aggregate,
      total: total
    } do
      assert total == 30

      prompt = ToolsSection.build()
      assert is_binary(prompt)

      # BEFORE this change the count on both of these lines was 0: the block did
      # not exist and no MCP name appeared anywhere in the prompt.
      visible_servers = Enum.count(@servers, &String.contains?(prompt, &1))
      assert visible_servers == length(@servers)

      visible_tools =
        aggregate
        |> Map.values()
        |> Enum.count(fn info -> String.contains?(prompt, info.original_name) end)

      assert visible_tools == total

      assert prompt =~ @catalog_marker
      # The block must state how to act on the names, not just list them.
      assert prompt =~ "tool_search"
      assert prompt =~ "select:mcp__"
      assert prompt =~ "server:"
    end

    test "no <mcp-servers> block is emitted when no MCP server is connected" do
      :persistent_term.put(@pt_key, %{})
      prompt = ToolsSection.build()

      assert is_binary(prompt)
      refute prompt =~ @catalog_marker
    end

    test "MCP tools that are NOT deferred are left out of the catalog" do
      # Below the virtualization threshold the schemas are injected directly, so
      # re-listing them would be pure prompt tax.
      :persistent_term.put(@pt_key, %{
        "mcp__gmail__send" => %{
          original_name: "send",
          description: "send mail",
          should_defer?: false
        }
      })

      prompt = ToolsSection.build()
      refute prompt =~ @catalog_marker
    end
  end

  describe "the catalog is queryable" do
    test "mcp_catalog/0 groups every tool under its server", %{total: total} do
      catalog = Registry.mcp_catalog()

      assert Enum.sort(Map.keys(catalog)) == Enum.sort(@servers)
      assert catalog |> Map.values() |> Enum.map(&length/1) |> Enum.sum() == total
      assert Registry.mcp_servers() == Enum.sort(@servers)
    end

    test "mcp_tools_for_server/1 returns the whole toolset, unranked" do
      assert length(Registry.mcp_tools_for_server("gmail")) == @tools_per_server
      assert Registry.mcp_tools_for_server("nope") == []
    end
  end

  describe "tool_search reaches MCP tools" do
    test "server:<name> returns ALL of one server's tools, past the top-N cutoff" do
      # A keyword search returns max_results (default 5). Enumerating a server
      # must not be capped by that.
      {:ok, out} = ToolSearch.execute(%{"query" => "server:gmail"}, ctx())

      assert out =~ "Found #{@tools_per_server} tool(s)"

      for i <- 1..@tools_per_server do
        assert out =~ "mcp__gmail__gmail_action_#{i}"
      end

      # Schemas, not just names — the point is to make the tools callable.
      assert out =~ "Parameters:"
      assert out =~ "Required: q"
    end

    test "server: on an unknown server names the servers that DO exist" do
      {:ok, out} = ToolSearch.execute(%{"query" => "server:nope"}, ctx())

      assert out =~ "No MCP server named 'nope'"

      for server <- @servers do
        assert out =~ server
      end
    end

    test "select: fetches an exact MCP tool schema" do
      {:ok, out} =
        ToolSearch.execute(%{"query" => "select:mcp__drive__drive_action_3"}, ctx())

      assert out =~ "mcp__drive__drive_action_3"
      assert out =~ "Required: q"
    end

    test "a keyword search that surfaces no MCP tool still names the servers" do
      # "file_read" matches builtins only; without the hint the model reads an
      # all-builtin result list as proof no MCP tool could be relevant.
      {:ok, out} = ToolSearch.execute(%{"query" => "file_read"}, ctx())

      assert out =~ "Also connected"

      for server <- @servers do
        assert out =~ server
      end
    end

    test "an unmatched select: suggests near misses instead of dead-ending" do
      {:ok, out} = ToolSearch.execute(%{"query" => "select:file_reed"}, ctx())

      assert out =~ "Closest known names:"
      assert out =~ "file_read"
      assert out =~ "Next step:"
    end
  end

  describe "keyword scoring" do
    test "an uppercase tool name is matched by a lowercase keyword" do
      # `Registry.search/2` compared an already-downcased keyword against the RAW
      # tool name, so any name carrying an uppercase character — which is most
      # server-supplied MCP names — could never match on its name.
      :persistent_term.put(@pt_key, %{
        "mcp__Gmail__SendMail" => %{
          original_name: "SendMail",
          description: "no keyword overlap here at all",
          should_defer?: true
        }
      })

      names = Registry.search("sendmail", limit: 10) |> Enum.map(& &1.name)
      assert "mcp__Gmail__SendMail" in names
    end
  end
end
