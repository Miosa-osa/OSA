defmodule OptimalSystemAgent.Plugins.Loader do
  @moduledoc """
  Boot-time plugin discovery and registration.

  When explicitly enabled, scans `~/.osa/plugins/*.exs`, compiles each file,
  and registers any modules that implement `Tools.Behaviour` or
  `MiosaTools.Behaviour` with the Tools.Registry. Also registers any modules
  implementing `ContextEngine` with the ContextEngine.Router.

  ## Plugin code is code

  A plugin file is arbitrary Elixir evaluated **in the agent's own BEAM node**,
  with the agent's full privileges: `:os.cmd/1`, the filesystem, and the
  provider API keys held in memory. There is no sandbox. Loading a plugin is
  equivalent to running a script as yourself — treat `~/.osa/plugins/` with the
  same care as `~/.bashrc`.

  Because of that, plugin loading is:

    * **off by default**, and
    * **opt-in only from operator-controlled configuration** (see below), and
    * refused for any file that fails the ownership/permission checks below.

  ## Enabling

  Any one of these turns it on:

      # config/config.exs (compiled into the release by the operator)
      config :optimal_system_agent, :plugins_enabled, true

      # ~/.osa/config.toml
      [plugins]
      enabled = true

      # ~/.osa/settings.json   (USER layer only)
      {"plugins": {"enabled": true}}

  ### Why the user settings layer only

  `Settings.get/2` resolves through the full cascade, which includes the
  **project** layer (`.osa/settings.json`, checked into whatever repo happens
  to be the cwd) and the **local** layer (`.osa/settings.local.json`, also
  inside the workspace directory). A repository that shipped
  `{"plugins": {"enabled": true}}` plus a `.exs` file would be self-enabling
  remote code execution on `cd`. This module therefore reads
  `Settings.layer(:user)` directly — `~/.osa/settings.json`, outside any
  workspace — and never consults the merged cascade. Workspace-supplied
  settings cannot enable plugin loading at any trust level.

  ## Verification before compiling

  Each candidate file must pass, or it is skipped and the refusal is logged
  with the file name and the reason:

    * the plugin directory itself must exist, be a real directory, be owned by
      the current user, and not be writable by anyone else;
    * the file must be a regular file (symlinks are resolved, and a symlink
      whose target escapes the plugin directory is refused);
    * it must be owned by the current user (uid match);
    * it must not be world-writable, nor group-writable via a *shared* group
      (a per-user private group where `gid == uid` is fine — that is the
      default on distributions that ship `umask 002`);
    * it must be at most #{div(256 * 1024, 1024)} KiB.

  A silently skipped plugin is its own bug, so every refusal produces a
  `Logger.warning` naming the path and the reason.

  ## Plugins cannot impersonate built-ins

    * A plugin tool whose `name/0` collides with an already-registered tool is
      refused. Without this a plugin could register itself as `file_read` and
      inherit that name's auto-approved permission tier.
    * A plugin context engine whose id collides with a built-in is refused by
      `ContextEngine.Router.register/2`.

  ## Plugins do not choose their own permission tier

  Plugin-contributed tools are recorded in `plugin_tool?/1` and are forced to
  the ask-for-approval path regardless of what their `safety/0` returns. A
  plugin declaring `safety: :read_only` gains nothing by it.

  ## Plugin file format

      # ~/.osa/plugins/my_tool.exs
      defmodule MyApp.WeatherTool do
        @behaviour OptimalSystemAgent.Tools.Behaviour

        @impl true
        def name, do: "get_weather"

        @impl true
        def description, do: "Get current weather for a city"

        @impl true
        def parameters do
          %{
            type: "object",
            properties: %{city: %{type: "string", description: "City name"}},
            required: ["city"]
          }
        end

        @impl true
        def execute(%{"city" => city}) do
          {:ok, "Weather in \#{city}: sunny, 72F"}
        end

        @impl true
        def safety, do: :read_only
      end

  A crash in one plugin file does not prevent others from loading.
  """

  import Bitwise

  require Logger

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Settings

  @plugin_dir "plugins"

  @world_write 0o002
  @group_write 0o020

  @max_plugin_bytes 256 * 1024
  @max_symlink_depth 8

  @plugin_tools_key {__MODULE__, :plugin_tools}
  @plugin_tool_names_key {__MODULE__, :plugin_tool_names}

  # ── Opt-in ────────────────────────────────────────────────────────────

  @doc """
  Is plugin loading enabled?

  False unless the operator turned it on via application config,
  `~/.osa/config.toml`, or the **user** layer of `~/.osa/settings.json`.
  Workspace-supplied settings are deliberately not consulted.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :plugins_enabled, false) or
      toml_enabled?() or
      user_settings_enabled?()
  end

  defp toml_enabled? do
    case ConfigFile.get(["plugins", "enabled"]) do
      v when is_boolean(v) -> v
      _ -> false
    end
  rescue
    _ -> false
  end

  # `~/.osa/settings.json` ONLY. Never `Settings.get/2` — that merges the
  # project and local layers, both of which live inside the workspace.
  defp user_settings_enabled? do
    case Settings.layer(:user) do
      %{"plugins" => %{"enabled" => v}} when is_boolean(v) -> v
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── Loading ───────────────────────────────────────────────────────────

  @doc """
  Load all plugins from `~/.osa/plugins/`.

  Returns `{:ok, []}` without touching the filesystem when plugin loading is
  disabled — in particular the plugin directory is NOT created.
  """
  @spec load() :: {:ok, [{module(), atom()}]} | {:error, term()}
  def load do
    if enabled?() do
      do_load()
    else
      {:ok, []}
    end
  end

  defp do_load do
    dir = plugin_dir()

    case verify_dir(dir) do
      :ok ->
        case File.ls(dir) do
          {:ok, files} ->
            exs_files = files |> Enum.filter(&String.ends_with?(&1, ".exs")) |> Enum.sort()
            results = Enum.flat_map(exs_files, &load_file(&1, dir))
            Logger.info("Plugins.Loader: loaded #{length(results)} plugin(s) from #{dir}")
            {:ok, results}

          {:error, reason} ->
            refuse(dir, "cannot list plugin directory: #{inspect(reason)}")
            {:error, reason}
        end

      :enoent ->
        # Enabled but never used: create it private so the first plugin dropped
        # in does not immediately fail the mode check.
        File.mkdir_p(dir)
        File.chmod(dir, 0o700)
        Logger.info("Plugins.Loader: created plugin directory #{dir} (mode 0700)")
        {:ok, []}

      {:error, reason} ->
        refuse(dir, reason)
        {:error, reason}
    end
  end

  @doc """
  Load a single plugin file. Returns `[{module, behaviour_type}]`.

  The file is verified (owner, mode, type, size, symlink containment) before
  a single byte is compiled. A refused file returns `[]` and logs why.
  """
  @spec load_file(String.t(), String.t() | nil) :: [{module(), atom()}]
  def load_file(filename, dir \\ nil) do
    path = if dir, do: Path.join(dir, filename), else: filename
    abs_path = Path.expand(path)
    root = if dir, do: Path.expand(dir), else: Path.dirname(abs_path)

    case verify_file(abs_path, root) do
      {:ok, real_path} ->
        Logger.info("Plugins.Loader: loading #{real_path}")

        case File.read(real_path) do
          {:ok, source} ->
            compile_and_register(source, real_path)

          {:error, reason} ->
            refuse(real_path, "cannot read: #{inspect(reason)}")
            []
        end

      {:error, reason} ->
        refuse(abs_path, reason)
        []
    end
  end

  @doc "Resolved plugin directory (`<config_dir>/plugins`)."
  @spec plugin_dir() :: String.t()
  def plugin_dir do
    Path.join(ConfigFile.config_dir(), @plugin_dir)
  end

  @doc """
  Run the pre-compile checks against `path`, contained to `root`.

  Exposed so the ownership/mode/symlink rules can be asserted directly against
  real files (a foreign-owned file cannot be manufactured in a temp dir
  without root). Returns `{:ok, real_path}` or `{:error, reason_string}`.
  """
  @spec verify_plugin_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def verify_plugin_file(path, root), do: verify_file(Path.expand(path), Path.expand(root))

  # ── Verification ──────────────────────────────────────────────────────

  # `:ok` | `:enoent` | `{:error, reason_string}`
  defp verify_dir(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory, uid: uid, gid: gid, mode: mode}} ->
        cond do
          not owned_by_current_user?(uid) ->
            {:error, "plugin directory is not owned by the current user #{owner_detail(uid)}"}

          v = mode_violation(mode, uid, gid) ->
            {:error,
             "plugin directory is #{v} — anyone with write access to it could drop " <>
               "code here; run `chmod 700 #{dir}`"}

          true ->
            :ok
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "plugin directory is not a directory (type #{inspect(type)})"}

      {:error, :enoent} ->
        :enoent

      {:error, reason} ->
        {:error, "cannot stat plugin directory: #{inspect(reason)}"}
    end
  end

  # `{:ok, real_path}` | `{:error, reason_string}`
  defp verify_file(path, root) do
    with {:ok, real_path} <- resolve_within(path, root, 0),
         {:ok, stat} <- lstat(real_path) do
      check_stat(real_path, stat)
    end
  end

  defp check_stat(path, %File.Stat{type: type, uid: uid, gid: gid, mode: mode, size: size}) do
    cond do
      type != :regular ->
        {:error, "not a regular file (type #{inspect(type)})"}

      not owned_by_current_user?(uid) ->
        {:error, "not owned by the current user #{owner_detail(uid)}"}

      v = mode_violation(mode, uid, gid) ->
        {:error, v}

      size > @max_plugin_bytes ->
        {:error, "exceeds the #{@max_plugin_bytes}-byte plugin size limit (#{size} bytes)"}

      true ->
        {:ok, path}
    end
  end

  # World-writable is always a refusal. Group-writable is a refusal only when
  # the group is genuinely shared: on distributions that use per-user private
  # groups (gid == uid, the reason `umask 002` is a safe default there) the
  # group bit grants nothing the owner bit does not already grant, and
  # refusing it would reject a freshly created directory on a stock Ubuntu.
  defp mode_violation(mode, uid, gid) do
    cond do
      (mode &&& @world_write) != 0 ->
        "world-writable (mode #{mode_str(mode)})"

      (mode &&& @group_write) != 0 and gid != uid ->
        "group-writable by a shared group (mode #{mode_str(mode)}, gid #{gid}, uid #{uid})"

      true ->
        nil
    end
  end

  # Follow symlinks explicitly so a link pointing outside the plugin directory
  # (e.g. at a file in a checked-out repo) is refused rather than compiled.
  defp resolve_within(_path, _root, depth) when depth > @max_symlink_depth do
    {:error, "symlink chain deeper than #{@max_symlink_depth} levels"}
  end

  defp resolve_within(path, root, depth) do
    case lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            resolved =
              if Path.type(target) == :absolute do
                Path.expand(target)
              else
                Path.expand(target, Path.dirname(path))
              end

            if inside?(resolved, root) do
              resolve_within(resolved, root, depth + 1)
            else
              {:error, "symlink escapes the plugin directory (points at #{resolved})"}
            end

          {:error, reason} ->
            {:error, "cannot read symlink: #{inspect(reason)}"}
        end

      {:ok, _} ->
        {:ok, path}

      {:error, reason} ->
        {:error, "cannot stat: #{inspect(reason)}"}
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, "cannot stat: #{inspect(reason)}"}
    end
  end

  defp mode_str(mode), do: "0o" <> Integer.to_string(mode &&& 0o7777, 8)

  defp owner_detail(uid) do
    case current_uid() do
      nil -> "(file uid #{uid}; current uid could not be determined)"
      mine -> "(file uid #{uid}, expected #{mine})"
    end
  end

  defp owned_by_current_user?(uid) do
    case current_uid() do
      # Fail CLOSED: if we cannot establish who we are, we cannot establish
      # that the file is ours, and the payload is arbitrary code execution.
      nil -> false
      mine -> uid == mine
    end
  end

  # Determined by creating a file and reading back its uid — exact, and needs
  # no shell. Cached for the life of the node.
  defp current_uid do
    case :persistent_term.get({__MODULE__, :uid}, :unset) do
      :unset ->
        uid = detect_uid()
        :persistent_term.put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  end

  defp detect_uid do
    probe =
      Path.join(
        System.tmp_dir!(),
        "osa_uid_probe_#{System.system_time(:nanosecond)}_#{:erlang.unique_integer([:positive])}"
      )

    File.write!(probe, "")

    try do
      case File.stat(probe) do
        {:ok, %File.Stat{uid: uid}} -> uid
        _ -> nil
      end
    after
      File.rm(probe)
    end
  rescue
    _ -> nil
  end

  defp refuse(path, reason) do
    Logger.warning("Plugins.Loader: REFUSED #{path} — #{reason}")
    :ok
  end

  # ── Compilation and registration ──────────────────────────────────────

  defp compile_and_register(source, path) do
    try do
      modules_before = :code.all_loaded() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      # `Code.compile_string/2` takes the file name as a BINARY. The previous
      # `file: path` keyword raised FunctionClauseError on every single plugin,
      # which the rescue below swallowed into a "failed to compile" warning.
      _results = Code.compile_string(source, path)

      modules_after = :code.all_loaded() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      new_modules = MapSet.difference(modules_after, modules_before) |> MapSet.to_list()

      registered = Enum.flat_map(new_modules, &register_module(&1, path))

      if registered == [] do
        Logger.warning("Plugins.Loader: no known behaviours found in #{path}")
      end

      registered
    rescue
      e ->
        Logger.error("Plugins.Loader: failed to compile #{path}: #{Exception.message(e)}")
        []
    end
  end

  defp register_module(mod, path) do
    behaviours = module_behaviours(mod)

    Enum.flat_map(behaviours, fn behaviour ->
      case behaviour do
        OptimalSystemAgent.Tools.Behaviour -> register_tool(mod, :tool, path)
        MiosaTools.Behaviour -> register_tool(mod, :miosa_tool, path)
        OptimalSystemAgent.Agent.ContextEngine -> register_engine(mod, path)
        _ -> []
      end
    end)
  end

  defp register_tool(mod, kind, path) do
    name = safe_tool_name(mod)

    cond do
      name == nil ->
        refuse(path, "tool #{inspect(mod)} has no usable name/0")
        []

      builtin_tool?(name) ->
        refuse(
          path,
          "tool #{inspect(mod)} tried to claim the existing tool id #{inspect(name)} — " <>
            "plugins may not shadow built-in tools (a shadowed name would also inherit " <>
            "that name's permission tier)"
        )

        []

      true ->
        try do
          OptimalSystemAgent.Tools.Registry.register(mod)
          track_plugin_tool(mod, name)

          Logger.info(
            "Plugins.Loader: registered #{kind} #{inspect(mod)} as #{inspect(name)} " <>
              "(approval-gated: plugin tools do not choose their own tier)"
          )

          [{mod, kind}]
        rescue
          e ->
            Logger.warning(
              "Plugins.Loader: failed to register #{kind} #{inspect(mod)}: #{Exception.message(e)}"
            )

            []
        end
    end
  end

  defp register_engine(mod, path) do
    name = module_name(mod)

    case OptimalSystemAgent.Agent.ContextEngine.Router.register(name, mod) do
      :ok ->
        Logger.info("Plugins.Loader: registered context-engine #{inspect(mod)} as :#{name}")
        [{mod, :context_engine}]

      {:error, {:builtin_conflict, _}} ->
        refuse(
          path,
          "context-engine #{inspect(mod)} tried to claim the built-in engine id :#{name}"
        )

        []
    end
  rescue
    e ->
      Logger.warning(
        "Plugins.Loader: failed to register context-engine #{inspect(mod)}: #{Exception.message(e)}"
      )

      []
  end

  defp safe_tool_name(mod) do
    case mod.name() do
      name when is_binary(name) and name != "" -> name
      name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp builtin_tool?(name) do
    OptimalSystemAgent.Tools.Registry.module_for(name) != nil
  rescue
    # Registry not up (unit tests, early boot): assume collision-free rather
    # than refusing everything, the tier forcing below still applies.
    _ -> false
  end

  # ── Plugin tool provenance ────────────────────────────────────────────

  defp track_plugin_tool(mod, name) do
    mods = :persistent_term.get(@plugin_tools_key, MapSet.new())
    names = :persistent_term.get(@plugin_tool_names_key, MapSet.new())
    :persistent_term.put(@plugin_tools_key, MapSet.put(mods, mod))
    :persistent_term.put(@plugin_tool_names_key, MapSet.put(names, name))
    :ok
  end

  @doc """
  Was this tool module contributed by a plugin?

  Callers use this to force plugin tools onto the approval path regardless of
  the tier the module declares for itself.
  """
  @spec plugin_tool?(module()) :: boolean()
  def plugin_tool?(mod) when is_atom(mod) do
    MapSet.member?(:persistent_term.get(@plugin_tools_key, MapSet.new()), mod)
  end

  def plugin_tool?(_), do: false

  @doc "Was this tool NAME contributed by a plugin?"
  @spec plugin_tool_name?(String.t()) :: boolean()
  def plugin_tool_name?(name) when is_binary(name) do
    MapSet.member?(:persistent_term.get(@plugin_tool_names_key, MapSet.new()), name)
  end

  def plugin_tool_name?(_), do: false

  @doc "All plugin-contributed tool names."
  @spec plugin_tool_names() :: [String.t()]
  def plugin_tool_names do
    :persistent_term.get(@plugin_tool_names_key, MapSet.new()) |> MapSet.to_list()
  end

  @doc false
  # Test support: forget every recorded plugin tool.
  def reset_plugin_tools do
    :persistent_term.put(@plugin_tools_key, MapSet.new())
    :persistent_term.put(@plugin_tool_names_key, MapSet.new())
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Extract the short name for a context engine module (e.g. MyApp.Engine -> :my_app_engine)
  defp module_name(mod) do
    mod
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.downcase()
    |> String.replace(".", "_")
    |> String.to_atom()
  end

  # Get the list of behaviours a module declares
  defp module_behaviours(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        try do
          mod.__info__(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end
end
