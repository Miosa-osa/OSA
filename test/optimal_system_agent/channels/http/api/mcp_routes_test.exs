defmodule OptimalSystemAgent.Channels.HTTP.API.MCPRoutesTest do
  @moduledoc """
  HTTP contract coverage for the /mcp routes, focused on `mcp_context` — the
  cost-visibility field a client (TUI status bar, `/mcp` panel) reads to show
  something like "12 MCP · ~417 tok" instead of leaving an operator to guess
  whether their connected servers are cheap or expensive.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.MCPRoutes
  alias OptimalSystemAgent.MCP.Client.ToolBridge
  alias OptimalSystemAgent.Tools.Registry

  @opts MCPRoutes.init([])
  @pt_key {Registry, :mcp_tools}

  defp call(conn), do: MCPRoutes.call(conn, @opts)
  defp decode(conn), do: Jason.decode!(conn.resp_body)

  setup do
    prior = :persistent_term.get(@pt_key, %{})
    prior_mode = Application.get_env(:optimal_system_agent, :mcp_virtualization)
    prior_thresh = Application.get_env(:optimal_system_agent, :mcp_virtualization_threshold)

    on_exit(fn ->
      :persistent_term.put(@pt_key, prior)
      restore(:mcp_virtualization, prior_mode)
      restore(:mcp_virtualization_threshold, prior_thresh)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp publish(server, count) do
    schemas =
      for i <- 1..count do
        %{"name" => "tool_#{i}", "description" => "d", "inputSchema" => %{"type" => "object"}}
      end

    tools = ToolBridge.build_tools(server, schemas, nil)
    :persistent_term.put(@pt_key, Map.merge(:persistent_term.get(@pt_key, %{}), tools))
  end

  describe "GET / — mcp_context" do
    test "is present with the expected shape even with no MCP tools configured" do
      :persistent_term.put(@pt_key, %{})

      body = conn(:get, "/") |> call() |> decode()

      assert %{
               "mcp_context" => %{
                 "tool_count" => 0,
                 "server_count" => 0,
                 "virtualized" => false,
                 "estimated_tokens" => 0
               }
             } = body

      assert is_list(body["servers"])
    end

    test "reflects a live aggregate above the virtualization threshold" do
      Application.put_env(:optimal_system_agent, :mcp_virtualization, :auto)
      Application.put_env(:optimal_system_agent, :mcp_virtualization_threshold, 10)
      publish("huge", 50)

      body = conn(:get, "/") |> call() |> decode()

      assert body["mcp_context"]["tool_count"] == 50
      assert body["mcp_context"]["server_count"] == 1
      assert body["mcp_context"]["virtualized"] == true
      assert is_integer(body["mcp_context"]["estimated_tokens"])
      assert body["mcp_context"]["estimated_tokens"] > 0
    end

    test "never 500s even if the estimate would raise" do
      # Corrupt entry: `Jason.encode!/1` inside the non-virtualized cost path
      # would blow up on a non-JSON-encodable value if it reached it; here we
      # just assert the route tolerates a nil-valued map instead of crashing.
      :persistent_term.put(@pt_key, %{"mcp__x__y" => nil})

      conn = conn(:get, "/") |> call()
      assert conn.status == 200
      assert %{"mcp_context" => %{}} = decode(conn)
    end
  end
end
