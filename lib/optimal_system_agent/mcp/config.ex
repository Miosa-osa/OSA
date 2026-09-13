defmodule OptimalSystemAgent.MCP.Config do
  @moduledoc """
  Parse `~/.osa/mcp.json` into a list of `%Server{}` structs.

  The file is Claude-Desktop-compatible: a top-level `mcpServers` object
  whose keys are server names and whose values describe how to reach each
  server. Presence of a `url` selects the `:http_sse` transport; otherwise
  a local `:stdio` subprocess (`command` + `args` + `env`) is used.

  Server names are sanitized to `[a-z0-9_]` so they compose cleanly into the
  `mcp__<server>__<tool>` tool-name convention.

  This module performs pure parsing only — no processes are started here.
  """

  require Logger

  alias OptimalSystemAgent.System.AtomicFile
  alias OptimalSystemAgent.System.JsonStore

  # Scope precedence for merge (later wins): user < project < local.
  @scopes [:local, :project, :user]

  defmodule Server do
    @moduledoc "A single configured MCP server."

    @type transport :: :stdio | :http_sse

    @type t :: %__MODULE__{
            name: String.t(),
            transport: transport(),
            command: String.t() | nil,
            args: [String.t()],
            env: %{String.t() => String.t()},
            url: String.t() | nil,
            headers: %{String.t() => String.t()},
            oauth: map() | nil,
            enabled: boolean(),
            tool_filter: [String.t()] | nil,
            scope: :local | :project | :user,
            source: atom()
          }

    defstruct name: nil,
              transport: :stdio,
              command: nil,
              args: [],
              env: %{},
              url: nil,
              headers: %{},
              oauth: nil,
              enabled: true,
              tool_filter: nil,
              scope: :user,
              # Where this server was discovered: `:osa` for native
              # (~/.osa, .mcp.json, .osa/mcp.local.json), an external tool tag
              # (`:codex`, `:claude_code`, `:claude_desktop`, `:cursor`), or
              # `:plugin` for a portable plugin bundle manifest. `/mcp` renders
              # this via `MCP.Discovery.source_label/1`.
              source: :osa
  end

  @doc "Absolute path to the MCP config file (`~/.osa/mcp.json`)."
  @spec config_path() :: String.t()
  def config_path do
    config_dir()
    |> Path.join("mcp.json")
  end

  @doc "All supported config scopes, most-specific first."
  @spec scopes() :: [:local | :project | :user]
  def scopes, do: @scopes

  @doc """
  Absolute path to the config file backing a scope.

    * `:user`    — `~/.osa/mcp.json` (global, trusted)
    * `:project` — `./.mcp.json` (repo-committed, requires approval)
    * `:local`   — `./.osa/mcp.local.json` (per-checkout, not committed, trusted)
  """
  @spec scope_path(:local | :project | :user) :: String.t()
  def scope_path(:user), do: config_path()
  def scope_path(:project), do: Path.join(OptimalSystemAgent.Workspace.Cwd.get(), ".mcp.json")

  def scope_path(:local),
    do: Path.join([OptimalSystemAgent.Workspace.Cwd.get(), ".osa", "mcp.local.json"])

  @doc "Load one scope's servers, tagging each with its scope. Never raises."
  @spec load_scope(:local | :project | :user) :: [Server.t()]
  def load_scope(scope) do
    case load(scope_path(scope)) do
      {:ok, servers} -> Enum.map(servers, &%{&1 | scope: scope})
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Load and merge all scopes into a deduped server list.

  Precedence (last write wins): user < project < local, so a `local` override
  of a server name shadows the `project` and `user` definitions.
  """
  @spec load_all() :: [Server.t()]
  def load_all do
    [:user, :project, :local]
    |> Enum.reduce(%{}, fn scope, acc ->
      Enum.reduce(load_scope(scope), acc, fn s, a -> Map.put(a, s.name, s) end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Servers eligible to start at boot.

  An MCP server definition is a command line — starting one is arbitrary
  process execution — so every WORKSPACE-SUPPLIED definition is gated:

    * `:user`    — `~/.osa/mcp.json`        — authored on this machine, always included
    * `:project` — `<cwd>/.mcp.json`        — requires `MCP.ProjectApproval`
    * `:local`   — `<cwd>/.osa/mcp.local.json` — requires workspace trust

  `:local` was previously treated as "not committed, therefore trusted". It is
  read out of the cwd like every other workspace file, and `.gitignore` does
  not stop a hostile repository from shipping one, so an untrusted clone could
  auto-execute an arbitrary command at boot with no prompt at all. It is now
  gated on the same workspace trust as `.osa/settings.local.json`.
  """
  @spec load_startup() :: [Server.t()]
  def load_startup do
    workspace_trusted = OptimalSystemAgent.Settings.project_trusted?()

    native =
      load_all()
      |> Enum.filter(fn
        %Server{scope: :project} = s -> OptimalSystemAgent.MCP.ProjectApproval.approved?(s.name)
        %Server{scope: :local} -> workspace_trusted
        _ -> true
      end)
      |> Enum.reject(&excluded?(&1.name))

    # Servers imported from other tools (Codex/Claude/Cursor). OPT-IN — see
    # `MCP.Discovery.import_enabled?/0`; `discover/0` returns [] when the
    # operator has not asked for the inheritance. Native servers always win on
    # name collision. Discovery is best-effort and never raises, but we still
    # guard the whole append.
    native_names = MapSet.new(native, & &1.name)

    imported =
      OptimalSystemAgent.MCP.Discovery.discover()
      |> Enum.reject(fn s -> MapSet.member?(native_names, s.name) end)

    native ++ imported
  rescue
    e ->
      Logger.warning(
        "[MCP.Config] load_startup failed, falling back to load!/0: #{Exception.message(e)}"
      )

      load!()
  end

  @doc """
  Sanitized names on the MCP deny list.

  Sources, unioned: the settings cascade key `"mcp_exclude"` (so
  `~/.osa/settings.json` can carry it) and `config :optimal_system_agent,
  :mcp_exclude`. Honoured for EVERY server source — OSA's own config, the
  project `.mcp.json`, and anything imported from another tool — so one noisy
  server can be killed without disabling a whole source.
  """
  @spec exclusions() :: MapSet.t(String.t())
  def exclusions do
    from_settings = normalize_exclusions(settings_get("mcp_exclude"))
    from_env = normalize_exclusions(Application.get_env(:optimal_system_agent, :mcp_exclude, []))

    MapSet.union(from_settings, from_env)
  end

  @doc "Whether `name` is on the MCP deny list (compared after sanitization)."
  @spec excluded?(String.t()) :: boolean()
  def excluded?(name) when is_binary(name), do: MapSet.member?(exclusions(), sanitize_name(name))
  def excluded?(_), do: false

  @doc """
  Sanitized names on the MCP import ALLOW list, or an empty set for "no
  restriction".

  Sources, unioned, mirroring `exclusions/0`: the settings cascade key
  `"mcp_import_only"` and `config :optimal_system_agent, :mcp_import_only`.

  This exists because the deny list is the wrong shape for foreign import.
  `mcp_import_foreign` is one switch over every server in every other tool's
  config — on this machine that is six config files and roughly twenty servers
  — so choosing the two you actually want means enumerating the eighteen you
  do not, and re-editing that list every time another tool gains a server. The
  allow list inverts it: name what you want, and anything discovered later
  stays out until you say otherwise.

  Applies ONLY to servers imported from other tools. OSA's own configs are
  servers the operator deliberately gave OSA, and are unaffected.
  """
  @spec import_only() :: MapSet.t(String.t())
  def import_only do
    from_settings = normalize_exclusions(settings_get("mcp_import_only"))

    from_env =
      normalize_exclusions(Application.get_env(:optimal_system_agent, :mcp_import_only, []))

    MapSet.union(from_settings, from_env)
  end

  @doc """
  Whether an imported server named `name` may load.

  An empty allow list means no restriction, so the default behaviour is
  unchanged. The deny list still wins: excluding a server is an explicit
  decision, and allowing it elsewhere must not quietly override that.
  """
  @spec import_allowed?(String.t()) :: boolean()
  def import_allowed?(name) when is_binary(name) do
    allow = import_only()

    cond do
      excluded?(name) -> false
      MapSet.size(allow) == 0 -> true
      true -> MapSet.member?(allow, sanitize_name(name))
    end
  end

  def import_allowed?(_), do: false

  defp normalize_exclusions(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&sanitize_name/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_exclusions(value) when is_binary(value), do: normalize_exclusions([value])
  defp normalize_exclusions(_), do: MapSet.new()

  # Settings reads must never take the boot path down. Trust-gated: an
  # untrusted project's `.osa/settings.json` must not be able to register MCP
  # servers (arbitrary subprocesses) before the workspace is trusted.
  defp settings_get(key) do
    OptimalSystemAgent.Settings.get_trusted(key)
  rescue
    _ -> nil
  end

  @doc """
  Add (or overwrite) a server entry in a scope file. `spec` is the raw
  Claude-Desktop-style value map (`command`/`args`/`env` or `url`/`headers`).
  Returns `{:ok, path}` on success.
  """
  @spec add_server(String.t(), map(), :local | :project | :user) ::
          {:ok, String.t()} | {:error, term()}
  def add_server(name, spec, scope) when is_binary(name) and is_map(spec) do
    path = scope_path(scope)

    # `read_raw/1` returns `%{}` for an unparseable file, which here means
    # `osa mcp add` rewrites mcp.json containing ONLY the new server and
    # silently deletes every other one the user configured. Read for write
    # instead, and refuse rather than clobber.
    with {:ok, raw} <- JsonStore.read_map_for_write(path),
         servers = Map.get(raw, "mcpServers", %{}),
         updated = Map.put(raw, "mcpServers", Map.put(servers, name, spec)),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- AtomicFile.write(path, Jason.encode!(updated, pretty: true)) do
      {:ok, path}
    else
      {:error, :corrupt} -> {:error, JsonStore.corrupt_message("MCP config", path)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Remove a server from a scope file. Matches on the raw key first, then on the
  sanitized name, so `/mcp remove` works whether the caller passes the raw or
  sanitized name. Returns `{:ok, path}` or `{:error, :not_found}`.
  """
  @spec remove_server(String.t(), :local | :project | :user) ::
          {:ok, String.t()} | {:error, term()}
  def remove_server(name, scope) do
    path = scope_path(scope)

    case JsonStore.read_map_for_write(path) do
      {:ok, raw} -> do_remove_server(name, path, raw)
      {:error, :corrupt} -> {:error, JsonStore.corrupt_message("MCP config", path)}
    end
  end

  defp do_remove_server(name, path, raw) do
    servers = Map.get(raw, "mcpServers", %{})

    # Fail closed on an ambiguous sanitized match: when two raw keys sanitize
    # to the same name, `Enum.find` would silently remove whichever collided
    # first — i.e. delete a server the operator did not name. Require either an
    # exact raw key or exactly ONE sanitized candidate.
    key =
      cond do
        Map.has_key?(servers, name) ->
          name

        true ->
          target = sanitize_name(name)

          case Enum.filter(Map.keys(servers), fn k -> sanitize_name(k) == target end) do
            [only] ->
              only

            [_ | _] = ambiguous ->
              Logger.warning(
                "[MCP.Config] Refusing to remove #{inspect(name)}: #{length(ambiguous)} " <>
                  "server keys sanitize to #{inspect(target)} (#{inspect(ambiguous)}). " <>
                  "Pass the exact key."
              )

              nil

            [] ->
              nil
          end
      end

    if key do
      updated = Map.put(raw, "mcpServers", Map.delete(servers, key))

      case AtomicFile.write(path, Jason.encode!(updated, pretty: true)) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc "List the scopes that define a server (by sanitized name)."
  @spec find_scopes(String.t()) :: [:local | :project | :user]
  def find_scopes(name) do
    sanitized = sanitize_name(name)

    Enum.filter(@scopes, fn scope ->
      Enum.any?(load_scope(scope), fn s -> s.name == sanitized end)
    end)
  end

  @doc """
  Load and parse the MCP config.

  Returns `{:ok, [%Server{}]}` on success (an empty list if the file is
  missing — MCP is optional), or `{:error, reason}` on malformed JSON.
  """
  @spec load() :: {:ok, [Server.t()]} | {:error, term()}
  def load(path \\ nil) do
    path = path || config_path()

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} -> {:ok, parse(decoded)}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:error, :enoent} ->
        # Missing config is not an error: MCP is opt-in.
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Like `load/1` but returns `[]` on any error, logging a warning. Convenient
  for boot paths that must never crash on a bad config file.
  """
  @spec load!() :: [Server.t()]
  def load!(path \\ nil) do
    case load(path) do
      {:ok, servers} ->
        servers

      {:error, reason} ->
        Logger.warning("[MCP.Config] Failed to load MCP config: #{inspect(reason)}")
        []
    end
  end

  @doc "Parse an already-decoded config map into `%Server{}` structs."
  @spec parse(map()) :: [Server.t()]
  def parse(%{"mcpServers" => servers}) when is_map(servers) do
    servers
    |> Enum.map(fn {name, spec} -> parse_server(name, spec) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  def parse(_), do: []

  # ── Private ───────────────────────────────────────────────────────────

  defp parse_server(name, spec) when is_map(spec) do
    sanitized = sanitize_name(name)

    if sanitized == "" do
      Logger.warning("[MCP.Config] Skipping server with empty/invalid name: #{inspect(name)}")
      nil
    else
      url = spec["url"]
      transport = if is_binary(url) and url != "", do: :http_sse, else: :stdio

      %Server{
        name: sanitized,
        transport: transport,
        command: spec["command"],
        args: string_list(spec["args"]),
        env: string_map(spec["env"]),
        url: url,
        headers: string_map(spec["headers"]),
        oauth: spec["oauth"],
        enabled: Map.get(spec, "enabled", true) != false,
        tool_filter: parse_tool_filter(spec["tools"] || spec["tool_filter"])
      }
    end
  end

  defp parse_server(name, _spec) do
    Logger.warning("[MCP.Config] Skipping malformed server spec for #{inspect(name)}")
    nil
  end

  @doc """
  Sanitize a server name to the `[a-z0-9_]` alphabet used in tool names.

  Runs of underscores collapse to a SINGLE `_`. That is not cosmetic: tool
  names are `mcp__<server>__<tool>` with `__` as the separator, so a server
  segment that itself contains `__` makes the key ambiguous — `a__b` + `c` and
  `a` + `b__c` produce the identical key `mcp__a__b__c`. Since the tool segment
  is parsed by splitting on the FIRST `__`, such a key routes to the wrong
  server, and a permission rule scoped to `a` grants a tool owned by `a__b`.
  Collapsing here makes `__` unrepresentable in a server segment, which is what
  makes the key injective. `ToolBridge` re-checks and fails closed anyway.
  """
  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  def sanitize_name(_), do: ""

  defp string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp string_list(_), do: []

  defp string_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp string_map(_), do: %{}

  defp parse_tool_filter(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_tool_filter(_), do: nil

  defp config_dir do
    Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()
  end
end
