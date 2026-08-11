defmodule OptimalSystemAgent.MCP.PluginManifest do
  @moduledoc """
  Read MCP servers declared by **portable plugin bundles** in `~/.osa/plugins/`.

  A plugin bundle is a directory that ships a manifest instead of code. Where
  `Plugins.Loader` compiles `~/.osa/plugins/*.exs` — arbitrary Elixir in OSA's
  own BEAM node — a bundle here is read as **data only**: this module compiles
  nothing, evaluates nothing, and starts no process. The worst a malformed
  manifest can do is be skipped.

  That distinction is why manifest reading is NOT gated on
  `Plugins.Loader.enabled?/0`. Enabling that switch grants in-process code
  execution; listing a declared MCP server grants nothing until the operator
  imports it. The gate that matters here is the MCP import gate — see
  `MCP.Discovery`, which surfaces these servers through the same
  offered-never-auto-run path as Codex/Claude/Cursor entries.

  ## Layout

      ~/.osa/plugins/
      └── my-plugin/
          ├── plugin.json      # bundle identity (optional)
          └── mcp.json         # MCP servers this bundle declares

  Only the operator-owned `~/.osa/plugins/` tree is scanned. A workspace cannot
  contribute a bundle, for the same reason `Plugins.Loader` refuses to read
  workspace settings: a repository that shipped a manifest would otherwise be
  registering servers merely because someone `cd`-ed into it.

  ## `mcp.json`

      {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers": {
          "deploy": {
            "type": "streamable-http",
            "url": "https://deploy.example.com/mcp",
            "headers": {"X-Tenant": "acme"}
          },
          "worker": {
            "type": "stdio",
            "command": "python",
            "args": ["${PLUGIN_ROOT}/server.py"],
            "env": {"CACHE": "${PLUGIN_DATA}/cache"}
          }
        }
      }

  `plugin.json` may carry the same `mcpServers` object inline; `mcp.json` wins
  on a name collision. `$schema` is recorded but not required — refusing a
  manifest for a missing schema URL would drop servers that are otherwise
  perfectly well formed.

  ## Transports

    * `"streamable-http"` / `"http"` → `:http_sse` (OSA's `Transport.Http`
      probes Streamable HTTP first)
    * `"sse"` → `:http_sse`. Accepted, unlike some implementations that refuse
      it, because OSA genuinely implements the legacy HTTP+SSE fallback.
    * `"stdio"` / omitted → `:stdio`
    * omitted `type` with a `url` present → `:http_sse`, matching `MCP.Config`

  ## Names

  Each server is exposed as `<plugin>_<server>` so two bundles declaring
  `worker` cannot collide, and neither can shadow a native or imported server
  of the same bare name. A single underscore is deliberate: the tool-name
  convention is `mcp__<server>__<tool>` and `MCP.Client.ToolBridge.parse_key/1`
  splits on the first `__`, so a `__` inside a server name would be parsed as
  the server/tool boundary.

  ## Placeholders

  `${PLUGIN_ROOT}` (the bundle directory) and `${PLUGIN_DATA}`
  (`~/.osa/plugin-data/<plugin>`) expand in `command`, `args` and `env` values.
  Anything else is left literal — a manifest is not a shell, and quietly
  interpolating `${HOME}` or `${AWS_SECRET_ACCESS_KEY}` out of OSA's environment
  would turn a declarative file into an exfiltration primitive. An expanded path
  that escapes its own base is refused.

  `${PLUGIN_DATA}` is resolved but never created: reading a manifest must not
  write to disk.

  Every refusal is skipped individually and logged at debug — one bad entry
  costs that entry, not the bundle and not the scan. Nothing here raises.
  """

  require Logger

  alias OptimalSystemAgent.MCP.Config
  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.Utils.Bom

  @plugins_subdir "plugins"
  @data_subdir "plugin-data"

  # Bundles are shallow by design: one directory per plugin.
  @max_bundles 200

  # A header name must be an RFC 7230 token; a value must not smuggle a newline.
  @header_name_re ~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/

  @placeholder_re ~r/\$\{(PLUGIN_ROOT|PLUGIN_DATA)\}/

  @doc """
  Every MCP server declared by a plugin bundle, as `%Server{source: :plugin}`.

  Returns `[]` when the plugin directory is absent — the overwhelmingly common
  case — and never raises.
  """
  @spec servers() :: [Server.t()]
  def servers, do: servers(plugins_dir())

  @doc "Like `servers/0` but scans `dir`. Exposed so tests can point at a fixture."
  @spec servers(String.t()) :: [Server.t()]
  def servers(dir) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.take(@max_bundles)
        |> Enum.flat_map(&bundle_servers(Path.join(dir, &1), &1))
        |> Enum.sort_by(& &1.name)

      # Missing plugin directory is the normal case, not an error.
      {:error, _} ->
        []
    end
  rescue
    e ->
      Logger.debug("[MCP.PluginManifest] scan of #{dir} failed: #{inspect(e)}")
      []
  end

  def servers(_), do: []

  @doc "Absolute path to the plugin bundle directory (`~/.osa/plugins`)."
  @spec plugins_dir() :: String.t()
  def plugins_dir, do: Path.join(config_dir(), @plugins_subdir)

  @doc """
  The writable data directory a bundle's `${PLUGIN_DATA}` expands to.

  Returned as a path only — this module never creates it.
  """
  @spec data_dir(String.t()) :: String.t()
  def data_dir(plugin) when is_binary(plugin),
    do: Path.join([config_dir(), @data_subdir, plugin])

  # ── Bundle reading ────────────────────────────────────────────────────

  defp bundle_servers(root, dirname) do
    if File.dir?(root) do
      plugin = plugin_name(root, dirname)

      # mcp.json is the dedicated file and wins; plugin.json may declare the
      # same object inline for single-file bundles.
      specs =
        Map.merge(
          mcp_servers_object(read_json(Path.join(root, "plugin.json"))),
          mcp_servers_object(read_json(Path.join(root, "mcp.json")))
        )

      data = data_dir(plugin)

      specs
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, spec} -> build_server(plugin, root, data, name, spec) end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  # A bundle's declared name is used only when it is a usable identifier;
  # otherwise the directory name is the identity, which always exists.
  defp plugin_name(root, dirname) do
    declared =
      case read_json(Path.join(root, "plugin.json")) do
        %{"name" => name} when is_binary(name) -> Config.sanitize_name(name)
        _ -> ""
      end

    if declared != "", do: declared, else: Config.sanitize_name(dirname)
  end

  defp mcp_servers_object(%{"mcpServers" => servers}) when is_map(servers), do: servers
  defp mcp_servers_object(_), do: %{}

  defp read_json(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- raw |> Bom.strip() |> Jason.decode() do
      decoded
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # ── Entry translation ─────────────────────────────────────────────────

  defp build_server(plugin, root, data, name, spec) when is_map(spec) do
    qualified = qualified_name(plugin, name)

    cond do
      plugin == "" or Config.sanitize_name(name) == "" ->
        refuse(plugin, name, "unusable server name")

      true ->
        case transport_of(spec) do
          :remote -> remote_server(qualified, plugin, name, spec)
          :stdio -> stdio_server(qualified, plugin, name, spec, root, data)
          :unknown -> refuse(plugin, name, "unknown MCP server type #{inspect(spec["type"])}")
        end
    end
  end

  defp build_server(plugin, _root, _data, name, _spec),
    do: refuse(plugin, name, "server entry is not an object")

  @doc """
  The runtime server name for a bundle's entry: `<plugin>_<server>`.

  Both halves are sanitized to the `[a-z0-9_]` alphabet first, so the result is
  always a legal MCP server name.
  """
  @spec qualified_name(String.t(), String.t()) :: String.t()
  def qualified_name(plugin, name) do
    "#{Config.sanitize_name(plugin)}_#{Config.sanitize_name(name)}"
    |> Config.sanitize_name()
    # `sanitize_name/1` preserves underscores, so a bundle or server called
    # `a__b` would carry a `__` straight into the tool key and be mis-parsed as
    # the server/tool boundary. Collapse runs to a single separator.
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp transport_of(%{"type" => type}) when is_binary(type) do
    case String.downcase(type) do
      "streamable-http" -> :remote
      "streamable_http" -> :remote
      "http" -> :remote
      "sse" -> :remote
      "stdio" -> :stdio
      _ -> :unknown
    end
  end

  # No declared type: fall back to MCP.Config's rule — a url means remote.
  defp transport_of(spec) do
    url = spec["url"]
    if is_binary(url) and url != "", do: :remote, else: :stdio
  end

  # ── Remote (streamable-http / sse) ────────────────────────────────────

  defp remote_server(qualified, plugin, name, spec) do
    with {:ok, url} <- validate_url(spec["url"]),
         {:ok, headers} <- validate_headers(spec["headers"]) do
      %Server{
        name: qualified,
        transport: :http_sse,
        url: url,
        headers: headers,
        enabled: Map.get(spec, "enabled", true) != false,
        tool_filter: tool_filter(spec),
        scope: :user,
        source: :plugin
      }
    else
      {:error, why} -> refuse(plugin, name, why)
    end
  end

  # An absolute http(s) URL with a host, no userinfo (credentials in a shared
  # manifest are a leak, not a feature) and no fragment. Plain http is allowed
  # only against loopback: a bundle is a portable artifact that may be installed
  # anywhere, and cleartext to an arbitrary host would ship the operator's
  # headers — commonly a bearer token — over the wire.
  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "url must be http or https"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "url has no host"}

      uri.userinfo not in [nil, ""] ->
        {:error, "url must not embed credentials"}

      uri.fragment not in [nil, ""] ->
        {:error, "url must not have a fragment"}

      uri.scheme == "http" and not loopback?(uri.host) ->
        {:error, "non-loopback url must be https"}

      true ->
        {:ok, URI.to_string(uri)}
    end
  end

  defp validate_url(_), do: {:error, "remote server has no url"}

  defp loopback?(host) do
    h = String.downcase(host)
    h in ["localhost", "127.0.0.1", "::1", "[::1]"] or String.starts_with?(h, "127.")
  end

  defp validate_headers(nil), do: {:ok, %{}}

  defp validate_headers(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      key = to_string(k)
      value = if is_binary(v), do: v, else: to_string(v)

      cond do
        not Regex.match?(@header_name_re, key) ->
          {:halt, {:error, "invalid header name #{inspect(key)}"}}

        String.contains?(value, "\n") or String.contains?(value, "\r") ->
          {:halt, {:error, "header #{inspect(key)} value contains a newline"}}

        Map.has_key?(acc, String.downcase(key)) ->
          {:halt, {:error, "duplicate header #{inspect(key)}"}}

        true ->
          {:cont, {:ok, Map.put(acc, String.downcase(key), value)}}
      end
    end)
  rescue
    _ -> {:error, "malformed headers"}
  end

  defp validate_headers(_), do: {:error, "headers must be an object"}

  # ── stdio ─────────────────────────────────────────────────────────────

  defp stdio_server(qualified, plugin, name, spec, root, data) do
    with {:ok, command} <- validate_command(spec["command"], root, data),
         {:ok, args} <- expand_list(spec["args"], root, data),
         {:ok, env} <- expand_env(spec["env"], root, data) do
      %Server{
        name: qualified,
        transport: :stdio,
        command: command,
        args: args,
        env: Map.merge(env, %{"PLUGIN_ROOT" => root, "PLUGIN_DATA" => data}),
        enabled: Map.get(spec, "enabled", true) != false,
        tool_filter: tool_filter(spec),
        scope: :user,
        source: :plugin
      }
    else
      {:error, why} -> refuse(plugin, name, why)
    end
  end

  # A command is either a bare token resolved through PATH, or a
  # `${PLUGIN_ROOT}`/`${PLUGIN_DATA}`-rooted absolute path.
  #
  # A `./`-relative command is REFUSED rather than resolved. `%Config.Server{}`
  # carries no working directory and `Transport.Stdio` spawns without one, so
  # `./server.py` would resolve against whatever directory OSA happens to be
  # running in — sometimes the bundle, usually not. Refusing says so; resolving
  # it silently would launch the wrong file, or the right file from the wrong
  # tree, with no indication either way.
  defp validate_command(command, root, data) when is_binary(command) do
    trimmed = String.trim(command)

    cond do
      trimmed == "" ->
        {:error, "empty command"}

      String.starts_with?(trimmed, "${PLUGIN_ROOT}") or
          String.starts_with?(trimmed, "${PLUGIN_DATA}") ->
        expand(trimmed, root, data)

      String.starts_with?(trimmed, "./") or String.starts_with?(trimmed, "../") ->
        {:error,
         "relative command #{inspect(trimmed)} — use ${PLUGIN_ROOT}/… " <>
           "(a plugin server is spawned with no working directory of its own)"}

      String.contains?(trimmed, "/") ->
        {:error, "command must be a bare executable name or ${PLUGIN_ROOT}-rooted"}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_command(_, _, _), do: {:error, "stdio server has no command"}

  defp expand_list(nil, _root, _data), do: {:ok, []}

  defp expand_list(list, root, data) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case expand(to_string(item), root, data) do
        {:ok, expanded} -> {:cont, {:ok, acc ++ [expanded]}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
  rescue
    _ -> {:error, "malformed args"}
  end

  defp expand_list(_, _, _), do: {:error, "args must be an array"}

  defp expand_env(nil, _root, _data), do: {:ok, %{}}

  defp expand_env(map, root, data) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case expand(to_string(v), root, data) do
        {:ok, expanded} -> {:cont, {:ok, Map.put(acc, to_string(k), expanded)}}
        {:error, why} -> {:halt, {:error, why}}
      end
    end)
  rescue
    _ -> {:error, "malformed env"}
  end

  defp expand_env(_, _, _), do: {:error, "env must be an object"}

  # Replace ${PLUGIN_ROOT}/${PLUGIN_DATA} and refuse a result that climbs out of
  # the base it claimed to be rooted in (`${PLUGIN_ROOT}/../../.ssh/id_rsa`).
  # Any other `${...}` is left verbatim — see the moduledoc.
  defp expand(value, root, data) when is_binary(value) do
    expanded =
      Regex.replace(@placeholder_re, value, fn _, var ->
        case var do
          "PLUGIN_ROOT" -> root
          "PLUGIN_DATA" -> data
        end
      end)

    base =
      cond do
        String.starts_with?(value, "${PLUGIN_ROOT}") -> root
        String.starts_with?(value, "${PLUGIN_DATA}") -> data
        true -> nil
      end

    if is_nil(base) or contained?(expanded, base) do
      {:ok, expanded}
    else
      {:error, "path #{inspect(value)} escapes its plugin root"}
    end
  end

  defp expand(value, _root, _data), do: {:ok, to_string(value)}

  defp contained?(path, base) do
    expanded = Path.expand(path)
    base = Path.expand(base)
    expanded == base or String.starts_with?(expanded, base <> "/")
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp tool_filter(spec) do
    case spec["tools"] || spec["tool_filter"] do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> nil
    end
  end

  defp refuse(plugin, name, why) do
    Logger.debug("[MCP.PluginManifest] skipped #{plugin}/#{name}: #{why}")
    nil
  end

  defp config_dir do
    Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()
  end
end
