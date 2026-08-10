defmodule OptimalSystemAgent.MCP.Discovery do
  @moduledoc """
  Read MCP servers a user configured in OTHER tools (Claude Code, Claude
  Desktop, Cursor, Codex).

  ## This is OPT-IN and OFF by default

  Importing another tool's MCP config is not a neutral convenience: every
  imported entry spawns a subprocess OSA's operator never authorized and adds
  tool definitions they never chose, with no attribution explaining where the
  server came from. `discover/0` therefore returns `[]` unless the operator
  explicitly opts in via `config :optimal_system_agent, mcp_import_foreign:
  true` or `{"mcp_import_foreign": true}` in `~/.osa/settings.json`.

  OSA's OWN configs are unaffected by this switch — `~/.osa/mcp.json`, the
  workspace `.mcp.json`, and `.osa/mcp.local.json` are servers the user
  deliberately gave OSA and always load (see `MCP.Config`).

  `available/0` reads the foreign sources regardless of the switch WITHOUT
  importing anything, so `/mcp` can tell the user "12 servers are available to
  import from claude_code" without silently running them.

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

  @doc "Every foreign source this module knows how to read, in precedence order."
  @spec all_sources() :: [atom()]
  def all_sources, do: @sources

  @doc """
  Whether importing OTHER tools' MCP configs is enabled.

  Resolution order (first present wins):

    1. `~/.osa/settings.json` (and the rest of the settings cascade) key
       `"mcp_import_foreign"`
    2. `config :optimal_system_agent, :mcp_import_foreign`
    3. `false` — the default

  `:mcp_discovery_enabled` remains a hard kill switch layered on top: when it
  is set to `false` (as `config/test.exs` does, so the suite never picks up the
  operator's real `$HOME`) no foreign config is imported regardless of the
  opt-in above.
  """
  @spec import_enabled?() :: boolean()
  def import_enabled? do
    kill_switch =
      Application.get_env(:optimal_system_agent, :mcp_discovery_enabled, true) != false

    kill_switch and opted_in?()
  end

  defp opted_in? do
    case settings_get("mcp_import_foreign") do
      value when is_boolean(value) ->
        value

      _ ->
        Application.get_env(:optimal_system_agent, :mcp_import_foreign, false) == true
    end
  end

  # Settings reads must never take discovery down (missing ETS at early boot,
  # unreadable file, etc.) — fall through to app env on any trouble.
  defp settings_get(key) do
    OptimalSystemAgent.Settings.get_trusted(key)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "The foreign sources that will be read when import is enabled."
  @spec sources() :: [atom()]
  def sources do
    case Application.get_env(:optimal_system_agent, :mcp_import_sources, @sources) do
      list when is_list(list) -> Enum.filter(@sources, &(&1 in list))
      _ -> @sources
    end
  end

  @doc """
  Import external MCP servers as `%Server{}` structs, deduped by name.

  Returns `[]` unless `import_enabled?/0` — foreign import is opt-in.

  Precedence among external tools follows `sources/0`; any name already defined
  natively (`Config.load_all/0`) is excluded so native always wins, and any name
  on the `mcp_exclude` deny list is dropped.
  """
  @spec discover() :: [Server.t()]
  def discover do
    if import_enabled?(), do: read_all(true), else: []
  end

  @doc """
  Read the foreign sources WITHOUT importing — always, regardless of the opt-in.

  This is the "here is what you could inherit" peek used by `/mcp` so the
  operator can see what exists in other tools' configs without OSA running any
  of it. Excluded names are still filtered out (an exclusion is a decision, not
  a suggestion).

  The `mcp_import_only` allow list is deliberately NOT applied here. This list
  is the menu you choose FROM, so filtering it by the choice already made would
  hide every server not yet picked - including the ones you opened `/mcp` to
  find. Use `importable?/1` to render which entries are currently active.
  """
  @spec available() :: [Server.t()]
  def available do
    kill_switch =
      Application.get_env(:optimal_system_agent, :mcp_discovery_enabled, true) != false

    if kill_switch, do: read_all(false), else: []
  end

  @doc """
  Whether a discovered server would actually be imported right now - the
  allow-list answer for one name, so `/mcp` can mark each row active or not
  without re-deriving the rule.
  """
  @spec importable?(String.t()) :: boolean()
  def importable?(name), do: Config.import_allowed?(name)

  defp read_all(apply_allow_list?) do
    native_names =
      Config.load_all()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    sources()
    |> Enum.reduce(%{}, fn source, acc ->
      Enum.reduce(servers_for(source), acc, fn server, a ->
        # put_new: earlier (higher-precedence) source keeps the entry.
        Map.put_new(a, server.name, server)
      end)
    end)
    |> Map.values()
    |> Enum.reject(fn s -> MapSet.member?(native_names, s.name) end)
    # Deny list applies to imported servers too — killing one noisy server must
    # not require turning the whole source off. On the import path the
    # `mcp_import_only` allow list is folded into the same check: empty means no
    # restriction (unchanged default), a non-empty list means ONLY those names
    # import, and an exclusion still wins over an allow. `available/0` passes
    # false so the menu keeps showing everything you could pick.
    |> Enum.filter(fn s ->
      if apply_allow_list?, do: Config.import_allowed?(s.name), else: not Config.excluded?(s.name)
    end)
    # Imported servers keep their parsed `enabled: true` and auto-connect on
    # boot — but ONLY reach this path when the operator opted in above, so
    # nothing runs unasked. This is additionally bounded by the failure cap in
    # `MCP.Client.ServerSession`:
    # a borrowed config that 404s or needs an absent key makes a bounded burst of
    # connect attempts (`@max_connect_failures`) then goes `:dormant` and stops
    # reconnecting, so it can no longer storm the daemon with an unbounded npx
    # loop (the ~1000-spawn boot cascade that previously forced these disabled).
    # Broken servers still show up in `/mcp` (as dormant/down); the operator can
    # fix and re-enable them. Native ~/.osa/mcp.json servers keep their own
    # enabled state as before.
    |> Enum.sort_by(& &1.name)
  rescue
    e ->
      Logger.debug("[MCP.Discovery] read_all/0 failed: #{inspect(e)}")
      []
  end

  @doc """
  Human-readable origin for a server's `:source` tag — the answer to "why is
  this server here?". `:osa` means it came from one of OSA's own config files.
  """
  @spec source_label(atom()) :: String.t()
  def source_label(:osa), do: "osa config"
  def source_label(:claude_code), do: "inherited from claude code"
  def source_label(:claude_desktop), do: "inherited from claude desktop"
  def source_label(:cursor), do: "inherited from cursor"
  def source_label(:codex), do: "inherited from codex"
  def source_label(other), do: "inherited from #{other}"

  @doc """
  The config file a foreign `:source` is read from, so the user can go delete
  the entry at the root. `nil` for `:osa` (use `MCP.Config.scope_path/1`) and
  for a source with no existing file on this machine.
  """
  @spec source_path(atom()) :: String.t() | nil
  def source_path(:codex), do: existing(Path.join([home(), ".codex", "config.toml"]))
  def source_path(:cursor), do: existing(Path.join([home(), ".cursor", "mcp.json"]))

  def source_path(:claude_code) do
    existing(Path.join([home(), ".claude", "mcp.json"])) ||
      existing(Path.join([home(), ".claude.json"]))
  end

  def source_path(:claude_desktop), do: claude_desktop_path()
  def source_path(_), do: nil

  defp existing(path), do: if(File.exists?(path), do: path)

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
    case claude_desktop_path() do
      nil -> []
      path -> servers_from_spec_map(read_json_mcp_servers(path), :claude_desktop)
    end
  end

  defp claude_desktop_path do
    [
      Path.join([
        home(),
        "Library",
        "Application Support",
        "Claude",
        "claude_desktop_config.json"
      ]),
      Path.join([home(), ".config", "Claude", "claude_desktop_config.json"]),
      appdata_claude_desktop()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&File.exists?/1)
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
