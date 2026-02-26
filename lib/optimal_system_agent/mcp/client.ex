defmodule OptimalSystemAgent.MCP.Client do
  @moduledoc """
  MCP (Model Context Protocol) client — connects to external MCP servers.

  Supports:
  - stdio: subprocess with JSON-RPC over stdin/stdout
  - HTTP/SSE: HTTP-based MCP servers

  Auto-discovers tools from MCP servers and makes them available
  to the agent loop alongside built-in skills.

  Config format (standard MCP protocol):
  ```json
  {
    "mcpServers": {
      "filesystem": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
      },
      "github": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-github"],
        "env": { "GITHUB_TOKEN": "..." }
      }
    }
  }
  ```
  """
  require Logger

  @mcp_config Application.compile_env(:optimal_system_agent, :mcp_config_path, "~/.osa/mcp.json")

  def load_servers do
    config_path = Path.expand(@mcp_config)

    if File.exists?(config_path) do
      case Jason.decode(File.read!(config_path)) do
        {:ok, %{"mcpServers" => servers}} ->
          Logger.info("Loaded #{map_size(servers)} MCP server configs")
          servers

        _ ->
          Logger.debug("No MCP servers configured")
          %{}
      end
    else
      %{}
    end
  end
end
