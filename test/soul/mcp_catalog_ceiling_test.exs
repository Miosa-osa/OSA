defmodule OptimalSystemAgent.Soul.McpCatalogCeilingTest do
  @moduledoc """
  MCP virtualization took the SCHEMAS out of the static prefix but left every
  tool NAME in the `<mcp-servers>` catalog, so the catalog was still
  O(total MCP tools) with no upper bound — a config that gains a server makes
  every request longer, forever.

  MEASURED against the operator's real 13-server config (7 reachable, 387 tools
  harvested over stdio): declared as native schemas 288,444 B (~72,111 tok);
  virtualized with every name 8,079 B (~2,020 tok); virtualized with this
  ceiling 1,669 B (~417 tok).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.ToolBridge
  alias OptimalSystemAgent.Soul.ToolsSection
  alias OptimalSystemAgent.Tools.Registry

  @pt_key {Registry, :mcp_tools}

  setup do
    prior = :persistent_term.get(@pt_key, %{})
    prior_mode = Application.get_env(:optimal_system_agent, :mcp_virtualization)
    prior_cap = Application.get_env(:optimal_system_agent, :mcp_catalog_names_per_server)

    Application.put_env(:optimal_system_agent, :mcp_virtualization, :on)

    on_exit(fn ->
      :persistent_term.put(@pt_key, prior)

      restore = fn key, val ->
        if is_nil(val),
          do: Application.delete_env(:optimal_system_agent, key),
          else: Application.put_env(:optimal_system_agent, key, val)
      end

      restore.(:mcp_virtualization, prior_mode)
      restore.(:mcp_catalog_names_per_server, prior_cap)
    end)

    :ok
  end

  defp publish(server, count) do
    schemas =
      for i <- 1..count do
        %{
          "name" => "tool_#{i}",
          "description" => "d",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      end

    tools = ToolBridge.build_tools(server, schemas, nil)
    :persistent_term.put(@pt_key, Map.merge(:persistent_term.get(@pt_key, %{}), tools))
  end

  defp catalog do
    prose = ToolsSection.build(:native_tools) || ""

    case Regex.run(~r/<mcp-servers>.*?<\/mcp-servers>/s, prose) do
      [m] -> m
      _ -> ""
    end
  end

  test "a server at or below the cap still lists every tool name by name" do
    Application.put_env(:optimal_system_agent, :mcp_catalog_names_per_server, 40)
    publish("small", 40)

    block = catalog()

    assert block =~ "**small** (40 tools):"
    assert block =~ "tool_1,"
    assert block =~ "tool_40"
    refute block =~ "names not listed"
  end

  test "a server above the cap collapses to a count plus an enumeration pointer" do
    Application.put_env(:optimal_system_agent, :mcp_catalog_names_per_server, 40)
    publish("huge", 300)

    block = catalog()

    # Still present, still counted, still reachable — the model has evidence the
    # server exists and an exact instruction for getting its names.
    assert block =~ "**huge** (300 tools)"
    assert block =~ "names not listed"
    assert block =~ "tool_search server:huge"

    # But its 300 names are not in the prefix.
    refute block =~ "tool_250"
  end

  test "the collapse is what bounds the catalog: a 10x tool count is not a 10x block" do
    Application.put_env(:optimal_system_agent, :mcp_catalog_names_per_server, 40)

    publish("a", 300)
    small = byte_size(catalog())

    :persistent_term.put(@pt_key, %{})
    publish("a", 3_000)
    large = byte_size(catalog())

    # The only difference between the two blocks is the printed count, so the
    # catalog is now O(servers), not O(tools). Without the ceiling `large`
    # would be ten times `small`.
    assert large - small < 32
  end

  test "mixed servers keep names where they are cheap and collapse only the outlier" do
    Application.put_env(:optimal_system_agent, :mcp_catalog_names_per_server, 40)

    publish("browsable", 12)
    publish("outlier", 333)

    block = catalog()

    assert block =~ "**browsable** (12 tools): tool_1,"
    assert block =~ "**outlier** (333 tools): names not listed"
  end
end
