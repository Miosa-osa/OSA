defmodule OptimalSystemAgent.SDK.MCP do
  @moduledoc """
  SDK wrapper for MCP (Model Context Protocol) integration.

  Lists configured MCP servers and their capabilities. MCP tools are
  auto-discovered and registered in Tools.Registry at boot.
  """

  @doc """
  List all configured MCP servers and their metadata.

  Reads from `~/.osa/mcp.json` (or the configured MCP config path).

  Returns a map of server_name => server_config.
  """
  @spec list_servers() :: map()
  def list_servers do
    try do
      OptimalSystemAgent.MCP.Client.load_servers()
    rescue
      _ -> %{}
    end
  end

  @doc """
  List all MCP-provided tools currently registered in Tools.Registry.

  MCP tools are prefixed with `mcp_` by convention.
  """
  @spec list_tools() :: [map()]
  def list_tools do
    OptimalSystemAgent.Tools.Registry.list_tools()
    |> Enum.filter(fn tool ->
      String.starts_with?(tool.name, "mcp_")
    end)
  end

  @doc "Reload MCP server configs from disk (after adding a new server to mcp.json)."
  @spec reload_servers() :: map()
  def reload_servers do
    list_servers()
  end
end
