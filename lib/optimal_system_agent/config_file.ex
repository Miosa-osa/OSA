defmodule OptimalSystemAgent.ConfigFile do
  @moduledoc """
  Standard, user-editable configuration for OSA.

  This is OSA's answer to Codex's `config.toml` and grok-build's typed TOML
  config: a single, documented, human-editable file at `~/.osa/config.toml`
  that lets an operator define their own parameters, permissions, and settings.

  ## Precedence (low → high)

      built-in defaults  <  ~/.osa/config.json  <  ~/.osa/config.toml

  1. **Built-in defaults** (`defaults/0`) — always present.
  2. **`config.json`** — the legacy persisted selection written by onboarding
     and the in-TUI model picker (`{"model": ..., "provider": ...}`). Read as a
     *fallback/overlay* so existing installs keep working with zero migration.
  3. **`config.toml`** — the new first-class config. Anything set here wins over
     both the legacy JSON and the defaults.

  Merging is a recursive deep-merge on maps: user config only needs to specify
  the keys it wants to override, everything else falls through to the default.

  ## Schema (see `priv/templates/config.toml` for the documented template)

      [model]        provider / model / effort / params.*
      [permissions]  ask_commands, ask_patterns, catastrophic_patterns,
                     allow, deny   (extend/override the shell three-tier gate)
      [shell]        timeout_ms
      [tui]          theme / verbosity
      [mcp_servers.*] pass-through server definitions (command/args/url/env)

  ## Typed getters

  Rather than making every call site reach into a raw map, this module exposes
  typed accessors (`provider/0`, `shell_timeout_ms/0`,
  `permission_ask_commands/0`, …). The shell permission tiers in
  `ShellExecute.Constants` layer these on top of their hardcoded defaults.

  The merged config is cached in `:persistent_term`, keyed by the resolved path
  and the two files' mtimes, so an edit to either file is picked up
  automatically on the next read without a restart. Call `reload/0` to force it.
  """

  require Logger

  @cache_key {__MODULE__, :resolved}

  # ── Built-in defaults ────────────────────────────────────────────────

  @doc """
  The built-in default configuration. This is the base every user config is
  deep-merged over. Permission lists here are intentionally EMPTY — the real
  shell defaults live in `ShellExecute.Constants` and this section only carries
  the operator's *extensions/overrides* on top of them.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      "model" => %{
        "provider" => nil,
        "model" => nil,
        "effort" => nil,
        "params" => %{}
      },
      "permissions" => %{
        # extend the risky (:ask) tier
        "ask_commands" => [],
        "ask_patterns" => [],
        # extend the catastrophic (hard-deny) tier
        "catastrophic_patterns" => [],
        # per-operator overrides
        "allow" => [],
        "deny" => []
      },
      "shell" => %{
        "timeout_ms" => nil
      },
      "tui" => %{
        "theme" => "dark",
        "verbosity" => "normal"
      },
      "mcp_servers" => %{}
    }
  end

  # ── Paths ─────────────────────────────────────────────────────────────

  @doc "Resolved config directory (respects `:config_dir` / `:bootstrap_dir`)."
  @spec config_dir() :: String.t()
  def config_dir do
    (Application.get_env(:optimal_system_agent, :config_dir) ||
       Application.get_env(:optimal_system_agent, :bootstrap_dir) ||
       "~/.osa")
    |> Path.expand()
  end

  @doc "Absolute path to `config.toml`."
  @spec toml_path() :: String.t()
  def toml_path, do: Path.join(config_dir(), "config.toml")

  @doc "Absolute path to the legacy `config.json`."
  @spec json_path() :: String.t()
  def json_path, do: Path.join(config_dir(), "config.json")

  # ── Load / cache ──────────────────────────────────────────────────────

  @doc """
  Returns the fully-merged configuration map (defaults < json < toml).

  Cached in `:persistent_term` and invalidated automatically when either
  backing file's mtime changes.
  """
  @spec load() :: map()
  def load do
    key = cache_signature()

    case :persistent_term.get(@cache_key, nil) do
      {^key, merged} ->
        merged

      _ ->
        merged = build()
        :persistent_term.put(@cache_key, {key, merged})
        merged
    end
  end

  @doc "Force the next `load/0` to re-read from disk."
  @spec reload() :: :ok
  def reload do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # Cache key: any change to path or file mtimes busts the cache.
  defp cache_signature do
    {toml_path(), file_mtime(toml_path()), json_path(), file_mtime(json_path())}
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      _ -> :missing
    end
  end

  defp build do
    defaults()
    |> deep_merge(json_overlay())
    |> deep_merge(toml_overlay())
  end

  # Map the legacy config.json ({model, provider, ...}) into the new schema.
  defp json_overlay do
    case read_json() do
      %{} = json when map_size(json) > 0 ->
        model =
          %{}
          |> put_if(json, "model", "model")
          |> put_if(json, "provider", "provider")

        if map_size(model) > 0, do: %{"model" => model}, else: %{}

      _ ->
        %{}
    end
  end

  defp put_if(acc, src, src_key, dest_key) do
    case Map.get(src, src_key) do
      v when is_binary(v) and v != "" -> Map.put(acc, dest_key, v)
      _ -> acc
    end
  end

  defp read_json do
    with true <- File.exists?(json_path()),
         {:ok, raw} <- File.read(json_path()),
         {:ok, %{} = json} <- Jason.decode(raw) do
      json
    else
      _ -> %{}
    end
  end

  defp toml_overlay do
    with true <- File.exists?(toml_path()),
         {:ok, raw} <- File.read(toml_path()),
         {:ok, %{} = parsed} <- parse_toml(raw) do
      parsed
    else
      false ->
        %{}

      {:error, reason} ->
        Logger.warning("[ConfigFile] Failed to parse #{toml_path()}: #{inspect(reason)}")
        %{}

      _ ->
        %{}
    end
  end

  defp parse_toml(raw) do
    :tomerl.parse(raw)
  rescue
    e -> {:error, e}
  catch
    _, reason -> {:error, reason}
  end

  # ── Deep merge ────────────────────────────────────────────────────────

  @doc "Recursively merge `override` over `base` (maps merge, everything else replaces)."
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _k, b, o ->
      if is_map(b) and is_map(o), do: deep_merge(b, o), else: o
    end)
  end

  # ── Generic getter ────────────────────────────────────────────────────

  @doc """
  Fetch a value by string-key path, falling back to `default`.

      get(["model", "provider"], "ollama")
  """
  @spec get([String.t()], term()) :: term()
  def get(path, default \\ nil) when is_list(path) do
    case get_in(load(), path) do
      nil -> default
      v -> v
    end
  end

  # ── Typed getters: model ──────────────────────────────────────────────

  @spec model_section() :: map()
  def model_section, do: get(["model"], %{}) || %{}

  @spec provider() :: String.t() | nil
  def provider, do: get(["model", "provider"])

  @spec model_name() :: String.t() | nil
  def model_name, do: get(["model", "model"])

  @spec effort() :: String.t() | nil
  def effort, do: get(["model", "effort"])

  @spec model_params() :: map()
  def model_params, do: get(["model", "params"], %{}) || %{}

  # ── Typed getters: shell / tui ────────────────────────────────────────

  @doc "Shell timeout override in ms, or nil if unset (caller keeps its default)."
  @spec shell_timeout_ms() :: pos_integer() | nil
  def shell_timeout_ms do
    case get(["shell", "timeout_ms"]) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  @spec tui_theme() :: String.t()
  def tui_theme, do: get(["tui", "theme"], "dark")

  @spec tui_verbosity() :: String.t()
  def tui_verbosity, do: get(["tui", "verbosity"], "normal")

  # ── Typed getters: mcp servers ────────────────────────────────────────

  @doc "Pass-through `[mcp_servers.*]` table (server-name → definition map)."
  @spec mcp_servers() :: map()
  def mcp_servers, do: get(["mcp_servers"], %{}) || %{}

  # ── Typed getters: permissions ────────────────────────────────────────
  #
  # These return ONLY the operator's config-supplied extensions/overrides.
  # `ShellExecute.Constants` combines them with its hardcoded @defaults.

  @spec permission_ask_commands() :: [String.t()]
  def permission_ask_commands, do: string_list(["permissions", "ask_commands"])

  @spec permission_ask_patterns() :: [Regex.t()]
  def permission_ask_patterns, do: regex_list(["permissions", "ask_patterns"])

  @spec permission_catastrophic_patterns() :: [Regex.t()]
  def permission_catastrophic_patterns,
    do: regex_list(["permissions", "catastrophic_patterns"])

  @doc "Command heads the operator always allows (downgrade risky → allow)."
  @spec permission_allow_commands() :: [String.t()]
  def permission_allow_commands, do: allow_commands()

  @doc "Regex patterns the operator always allows (downgrade risky → allow)."
  @spec permission_allow_patterns() :: [Regex.t()]
  def permission_allow_patterns, do: allow_patterns()

  @doc "Command heads the operator always hard-denies (treated as catastrophic)."
  @spec permission_deny_commands() :: [String.t()]
  def permission_deny_commands, do: deny_commands()

  @doc "Regex patterns the operator always hard-denies (treated as catastrophic)."
  @spec permission_deny_patterns() :: [Regex.t()]
  def permission_deny_patterns, do: deny_patterns()

  # allow/deny entries may be a bare command name ("rm") or a regex-ish pattern.
  # A bare token (word chars, dot, dash only) is treated as a command head; any
  # entry containing regex metacharacters is compiled as a pattern.
  defp allow_commands, do: split_rules(["permissions", "allow"]) |> elem(0)
  defp allow_patterns, do: split_rules(["permissions", "allow"]) |> elem(1)
  defp deny_commands, do: split_rules(["permissions", "deny"]) |> elem(0)
  defp deny_patterns, do: split_rules(["permissions", "deny"]) |> elem(1)

  defp split_rules(path) do
    Enum.reduce(string_list(path), {[], []}, fn entry, {cmds, pats} ->
      if bare_command?(entry) do
        {[entry | cmds], pats}
      else
        case Regex.compile(entry) do
          {:ok, re} -> {cmds, [re | pats]}
          _ -> {cmds, pats}
        end
      end
    end)
    |> then(fn {c, p} -> {Enum.reverse(c), Enum.reverse(p)} end)
  end

  defp bare_command?(entry), do: Regex.match?(~r/^[\w.\-]+$/, entry)

  # ── Value coercion helpers ────────────────────────────────────────────

  defp string_list(path) do
    load()
    |> get_in(path)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp regex_list(path) do
    string_list(path)
    |> Enum.map(&Regex.compile/1)
    |> Enum.flat_map(fn
      {:ok, re} -> [re]
      _ -> []
    end)
  end

  # ── First-run template ────────────────────────────────────────────────

  @doc """
  The documented default `config.toml` template shipped in `priv/templates`.
  Falls back to a minimal inline stub if the priv file can't be located.
  """
  @spec default_template() :: String.t()
  def default_template do
    path =
      :optimal_system_agent
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("templates/config.toml")

    case File.read(path) do
      {:ok, contents} -> contents
      _ -> "# OSA configuration\n# See docs/configuration.md\n"
    end
  end

  @doc """
  Write the documented default template to `~/.osa/config.toml` if it does not
  already exist. Never clobbers an existing operator config. Returns
  `{:ok, path}` when written, `{:ok, :exists}` when already present.
  """
  @spec write_default_template() :: {:ok, String.t() | :exists} | {:error, term()}
  def write_default_template do
    path = toml_path()

    if File.exists?(path) do
      {:ok, :exists}
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, default_template()) do
        reload()
        Logger.debug("[ConfigFile] Seeded default config → #{path}")
        {:ok, path}
      end
    end
  end
end
