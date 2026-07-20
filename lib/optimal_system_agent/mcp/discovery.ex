defmodule OptimalSystemAgent.MCP.Discovery do
  @moduledoc """
  Auto-discover MCP servers a user already configured in OTHER tools so they
  "just appear" in OSA with no manual setup.

  Each external source is read best-effort: a missing file is skipped, a
  malformed file is logged at debug level and skipped, and NOTHING here ever
  raises. Every discovered server is parsed through `MCP.Config` (reusing the
  Claude-Desktop-style struct builder) and tagged with a `:source` atom naming
  the tool it came from.

  Sources and precedence (first wins on name collision):

    1. `:codex`         — `~/.codex/config.toml` (`[mcp_servers.NAME]`, TOML)
    2. `:claude_code`   — `~/.claude/mcp.json` and `~/.claude.json`
    3. `:claude_desktop`— platform `claude_desktop_config.json`
    4. `:cursor`        — `~/.cursor/mcp.json`

  Native OSA servers (`Config.load_all/0`) always win over any discovered
  server of the same name; that precedence is applied in `Config.load_startup/0`,
  but `discover/0` also excludes native names so it never returns a duplicate.

  HOME is resolved at RUNTIME (never frozen into a module attribute). Tests can
  inject a fake home via `:discovery_home_override`.
  """

  require Logger

  alias OptimalSystemAgent.MCP.Config
  alias OptimalSystemAgent.MCP.Config.Server

  # Sources in precedence order (earlier wins on name collision).
  @sources [:codex, :claude_code, :claude_desktop, :cursor]

  @doc """
  Discover external MCP servers as `%Server{}` structs, deduped by name.

  Precedence among external tools follows `@sources`; any name already defined
  natively (`Config.load_all/0`) is excluded so native always wins.
  """
  @spec discover() :: [Server.t()]
  def discover do
    native_names =
      Config.load_all()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    @sources
    |> Enum.reduce(%{}, fn source, acc ->
      Enum.reduce(servers_for(source), acc, fn server, a ->
        # put_new: earlier (higher-precedence) source keeps the entry.
        Map.put_new(a, server.name, server)
      end)
    end)
    |> Map.values()
    |> Enum.reject(fn s -> MapSet.member?(native_names, s.name) end)
    # Discovered servers are DETECTED and listed, but NOT auto-connected on boot.
    # Auto-spawning every external server at startup storms the daemon: many
    # borrowed configs point at packages that 404 or need env/keys that are not
    # present, and each failed stdio server reconnects in a loop (observed ~1000
    # npx spawns from 13 servers, killing boot). Marking them disabled means they
    # show up in `/mcp` (the whole point of discovery) and the operator enables the
    # ones that actually work. Native ~/.osa/mcp.json servers keep their own
    # enabled state and still auto-connect. A capped auto-connect (bounded retries
    # then dormant) can safely re-enable auto-load later.
    |> Enum.map(fn s -> %{s | enabled: false} end)
    |> Enum.sort_by(& &1.name)
  rescue
    e ->
      Logger.debug("[MCP.Discovery] discover/0 failed: #{inspect(e)}")
      []
  end

  # ── Per-source readers ────────────────────────────────────────────────

  defp servers_for(:codex), do: read_codex()
  defp servers_for(:claude_code), do: read_claude_code()
  defp servers_for(:claude_desktop), do: read_claude_desktop()
  defp servers_for(:cursor), do: read_cursor()

  # Codex: TOML with an `[mcp_servers.NAME]` table per server.
  defp read_codex do
    path = Path.join([home(), ".codex", "config.toml"])

    with {:ok, raw} <- read_file(path),
         {:ok, map} <- parse_toml(path, raw) do
      map
      |> Map.get("mcp_servers", %{})
      |> case do
        servers when is_map(servers) -> servers_from_spec_map(servers, :codex)
        _ -> []
      end
    else
      _ -> []
    end
  end

  # Claude Code: merge ~/.claude/mcp.json and ~/.claude.json (both top-level
  # "mcpServers"). The per-user mcp.json wins on collision.
  defp read_claude_code do
    global = read_json_mcp_servers(Path.join([home(), ".claude.json"]))
    scoped = read_json_mcp_servers(Path.join([home(), ".claude", "mcp.json"]))

    merged = Map.merge(global, scoped)
    servers_from_spec_map(merged, :claude_code)
  end

  # Claude Desktop: first existing of the platform config locations.
  defp read_claude_desktop do
    candidates = [
      Path.join([home(), "Library", "Application Support", "Claude", "claude_desktop_config.json"]),
      Path.join([home(), ".config", "Claude", "claude_desktop_config.json"]),
      appdata_claude_desktop()
    ]

    candidates
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> []
      path -> servers_from_spec_map(read_json_mcp_servers(path), :claude_desktop)
    end
  end

  defp read_cursor do
    path = Path.join([home(), ".cursor", "mcp.json"])
    servers_from_spec_map(read_json_mcp_servers(path), :cursor)
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Turn a raw `%{NAME => spec}` map into `%Server{}` structs tagged with
  # `source`, reusing Config.parse for the struct-building. Servers with neither
  # a valid command nor url are dropped.
  defp servers_from_spec_map(spec_map, source) when is_map(spec_map) do
    %{"mcpServers" => spec_map}
    |> Config.parse()
    |> Enum.map(fn s -> %{s | source: source, scope: :user, enabled: true} end)
    |> Enum.filter(&valid_server?/1)
  end

  defp servers_from_spec_map(_, _), do: []

  # A usable server needs an http/sse url OR a non-empty stdio command.
  defp valid_server?(%Server{transport: :http_sse, url: url}),
    do: is_binary(url) and url != ""

  defp valid_server?(%Server{transport: :stdio, command: cmd}),
    do: is_binary(cmd) and cmd != ""

  defp valid_server?(_), do: false

  # Read a JSON file and return its top-level "mcpServers" object, or %{}.
  defp read_json_mcp_servers(path) do
    with {:ok, raw} <- read_file(path),
         {:ok, decoded} <- decode_json(path, raw),
         %{"mcpServers" => servers} when is_map(servers) <- decoded do
      servers
    else
      _ -> %{}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      # Missing file is normal (tool not installed); skip silently.
      {:error, _} -> :skip
    end
  end

  defp parse_toml(path, raw) do
    case :tomerl.parse(raw) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      other ->
        Logger.debug("[MCP.Discovery] Malformed TOML at #{path}: #{inspect(other)}")
        :skip
    end
  rescue
    e ->
      Logger.debug("[MCP.Discovery] TOML parse crashed at #{path}: #{inspect(e)}")
      :skip
  end

  defp decode_json(path, raw) do
    case Jason.decode(raw) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        Logger.debug("[MCP.Discovery] Malformed JSON at #{path}: #{inspect(reason)}")
        :skip
    end
  end

  defp appdata_claude_desktop do
    case System.get_env("APPDATA") do
      dir when is_binary(dir) and dir != "" ->
        Path.join([dir, "Claude", "claude_desktop_config.json"])

      _ ->
        nil
    end
  end

  # Runtime HOME resolver. Tests inject a fake home via :discovery_home_override;
  # otherwise the real user home is used. NEVER read the OSA_HOME override here —
  # that is only for OSA's own ~/.osa config, not for other tools' files.
  defp home do
    case Application.get_env(:optimal_system_agent, :discovery_home_override) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> System.user_home!()
    end
  end
end
