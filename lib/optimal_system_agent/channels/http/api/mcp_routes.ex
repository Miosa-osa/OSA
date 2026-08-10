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
    loaded =
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

    json(conn, 200, %{servers: loaded ++ offered(loaded)})
  end

  # ── POST /:name/toggle — turn a discovered server on or off ──────────
  #
  # Writes the `mcp_import_only` allow list in USER settings, which is the
  # same key `MCP.Config.import_allowed?/1` reads. Toggling is only meaningful
  # for servers inherited from another tool: OSA's own `mcp.json` entries are
  # ones the operator wrote deliberately, and this endpoint will not silently
  # rewrite that file.
  post "/:name/toggle" do
    name = to_string(name)

    case toggle_import(name) do
      {:ok, enabled?} ->
        # Re-read config so the change is live without a restart.
        _ = safe_reload()
        json(conn, 200, %{name: name, enabled: enabled?, restart_required: false})

      {:error, :native} ->
        json_error(
          conn,
          409,
          "native_server",
          "#{name} is defined in your own ~/.osa/mcp.json — edit that file to change it."
        )

      {:error, :unknown} ->
        json_error(conn, 404, "unknown_server", "No discoverable MCP server named #{name}.")

      {:error, reason} ->
        json_error(conn, 500, "toggle_failed", "Could not update settings: #{inspect(reason)}")
    end
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
      tool_count: server[:tool_count] || 0,
      # Native entries are the operator's own mcp.json and are not toggleable
      # from here; imported ones are.
      toggleable: stringify(server[:source] || :osa) != "osa"
    }
  end

  defp serialize_server(_), do: %{}

  # Servers OSA can SEE in another tool's config but is not currently running,
  # because the `mcp_import_only` allow list does not name them.
  #
  # Without these the panel could only ever show what is already on, so there
  # was nothing to turn ON — the list looked complete while hiding most of the
  # choices. They are reported with `status: "available"` and `enabled: false`
  # so a UI can render them as off rather than as broken.
  defp offered(loaded) do
    have = MapSet.new(loaded, & &1.name)

    OptimalSystemAgent.MCP.Discovery.available()
    |> Enum.reject(&MapSet.member?(have, &1.name))
    |> Enum.map(fn s ->
      %{
        name: stringify(s.name),
        transport: stringify(s.transport),
        enabled: false,
        status: "available",
        source: stringify(s.source || :osa),
        scope: stringify(s.scope || :user),
        tool_count: 0,
        toggleable: true
      }
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Add or remove `name` from the user-scope `mcp_import_only` allow list.
  # Returns {:ok, now_enabled?}.
  defp toggle_import(name) do
    alias OptimalSystemAgent.MCP.{Config, Discovery}

    native? = Enum.any?(Config.load_all(), &(&1.name == name and (&1.source || :osa) == :osa))
    known? = Enum.any?(Discovery.available(), &(&1.name == name))

    cond do
      native? ->
        {:error, :native}

      not known? ->
        {:error, :unknown}

      true ->
        current = current_allow_list()

        # An EMPTY allow list means "no restriction", so everything discovered
        # is already on. Turning one off from that state has to first make the
        # list explicit — otherwise removing a name from [] is a no-op and the
        # toggle would silently do nothing.
        base =
          if current == [],
            do: Enum.map(Discovery.available(), & &1.name),
            else: current

        {updated, enabled?} =
          if name in base,
            do: {List.delete(base, name), false},
            else: {Enum.sort([name | base]), true}

        case OptimalSystemAgent.Settings.set_user("mcp_import_only", updated) do
          :ok -> {:ok, enabled?}
          other -> {:error, other}
        end
    end
  end

  defp current_allow_list do
    case OptimalSystemAgent.Settings.get_trusted("mcp_import_only") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  rescue
    _ -> []
  end

  # Re-read config and reconcile running sessions so a toggle takes effect
  # without a restart. Never allowed to fail the request: the settings write
  # already succeeded, and reporting an error here would imply it had not.
  defp safe_reload do
    OptimalSystemAgent.Tools.Registry.register_mcp_tools()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Stringify atom values (nil-safe) so the TUI never sees raw atoms.
  defp stringify(nil), do: nil
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)
end
