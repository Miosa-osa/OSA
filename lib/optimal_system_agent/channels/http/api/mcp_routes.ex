defmodule OptimalSystemAgent.Channels.HTTP.API.MCPRoutes do
  @moduledoc """
  MCP (Model Context Protocol) client introspection routes.

  Forwarded prefix: /mcp

  Effective routes:
    GET /  (forwarded as GET /mcp)
      Lists configured MCP servers with their live status, sourced from
      `MCP.Client.Manager.list_servers/0`. Atom values (transport, status)
      are stringified so the TUI receives clean JSON. No PIDs/refs are
      exposed. On any failure, returns 200 with an empty server list —
      never 500s the TUI.

      Shape:
        {
          "servers": [
            {
              "name": "filesystem",
              "transport": "stdio",
              "enabled": true,
              "status": "connected",
              "tool_count": 7
            }
          ]
        }
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — list configured MCP servers ─────────────────────────────

  get "/" do
    servers =
      try do
        OptimalSystemAgent.MCP.Client.Manager.list_servers()
        |> Enum.map(&serialize_server/1)
      rescue
        e ->
          Logger.warning("[MCPRoutes] Failed to list servers: #{Exception.message(e)}")
          []
      catch
        :exit, _ -> []
      end

    json(conn, 200, %{servers: servers})
  end

  # ── catch-all ────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "MCP endpoint not found")
  end

  # ── Private helpers ──────────────────────────────────────────────────

  # Normalize a server map from Manager.list_servers/0 into a clean,
  # JSON-safe map. transport/status are atoms and must be stringified.
  defp serialize_server(server) when is_map(server) do
    %{
      name: stringify(server[:name]),
      transport: stringify(server[:transport]),
      enabled: server[:enabled] == true,
      status: stringify(server[:status]),
      source: stringify(server[:source] || :osa),
      scope: stringify(server[:scope] || :user),
      tool_count: server[:tool_count] || 0
    }
  end

  defp serialize_server(_), do: %{}

  # Stringify atom values (nil-safe) so the TUI never sees raw atoms.
  defp stringify(nil), do: nil
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)
end
