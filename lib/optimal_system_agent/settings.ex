defmodule OptimalSystemAgent.Settings do
  @moduledoc """
  Multi-layer settings cascade.

  Settings are resolved through 4 layers (highest priority last):

  1. **User** — `~/.osa/settings.json` (global user preferences)
  2. **Project** — `.osa/settings.json` (checked into repo, shared with team)
  3. **Local** — `.osa/settings.local.json` (gitignored, per-developer overrides)
  4. **Flag** — file named by `--settings <file>` / `OSA_SETTINGS` (optional)
  5. **Session** — in-memory only, set via API or CLI commands

  Layers are DEEP-merged: nested maps merge recursively, arrays concatenate
  and dedupe, higher-priority scalars win (explicit `false`/`null` included —
  presence-based, no falsy fallthrough).

  File reads are cached in the `:osa_settings_cache` ETS table keyed by
  `{path, {mtime, size}}`; `reset_cache/0` is the single reset, called by the
  file watcher and by every internal write.
  """
  require Logger

  @user_settings Path.expand("~/.osa/settings.json")
  @cache_table :osa_settings_cache

  @doc """
  Get a setting by key, resolved through the deep-merged cascade.

  Resolution is presence-based (`Map.fetch` on the merged map), so an explicit
  `false` or `null` in a higher-priority layer is honored instead of falling
  through to a lower layer or the default (CC `updateSettingsForSource`
  semantics).
  """
  def get(key, default \\ nil) do
    case Map.fetch(merged(), to_string(key)) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  All settings deep-merged through the cascade (lowest → highest priority):
  user → project → local → flag file → session.
  """
  def merged do
    [layer(:user), layer(:project), layer(:local), layer(:flag)]
    |> Enum.reduce(%{}, &deep_merge(&2, &1))
    |> deep_merge(get_all_session())
  end

  @doc "Deep-merge two settings maps: maps merge recursively, lists concat + dedupe, scalars override."
  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _k, a, b when is_map(a) and is_map(b) -> deep_merge(a, b)
      _k, a, b when is_list(a) and is_list(b) -> Enum.uniq(a ++ b)
      _k, _a, b -> b
    end)
  end

  @doc """
  Apply the merged `\"env\"` settings key to the OS environment.

  Only string → string entries are applied. Called at boot and re-applied
  live by `Settings.Watcher` whenever a settings file changes on disk.
  """
  def apply_env_settings do
    case Map.get(merged(), "env") do
      env when is_map(env) ->
        Enum.each(env, fn
          {k, v} when is_binary(k) and is_binary(v) ->
            try do
              System.put_env(k, v)
            rescue
              _ -> Logger.warning("[settings] Invalid env var name in settings: #{inspect(k)}")
            end

          _ ->
            :ok
        end)

      _ ->
        :ok
    end
  end

  @doc "Drop every cached settings file read (single reset — next read re-parses)."
  def reset_cache do
    :ets.delete_all_objects(@cache_table)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Absolute paths of all file-backed settings sources (watched for changes)."
  def source_paths do
    [@user_settings, project_settings_path(), local_settings_path()] ++
      List.wrap(flag_settings_path())
  end

  @doc "Set a session-level setting (in-memory only, not persisted)."
  def set_session(key, value) do
    try do
      :ets.insert(:osa_settings, {{:session, key}, value})
    rescue
      _ -> :ok
    end
  end

  @doc """
  Set a user-level setting (persisted to ~/.osa/settings.json).

  Refuses to overwrite an existing-but-unparseable settings file — returns
  `{:error, :corrupt_settings_file}` so a corrupt file is never clobbered.
  """
  def set_user(key, value), do: set_in_file(@user_settings, key, value)

  @doc "Set a project-level setting (persisted to .osa/settings.json). Refuses to overwrite a corrupt file."
  def set_project(key, value), do: set_in_file(project_settings_path(), key, value)

  @doc "Delete a key from the user settings file (write-side delete semantics)."
  def delete_user(key), do: update_in_file(@user_settings, &Map.delete(&1, to_string(key)))

  @doc "Delete a key from the project settings file."
  def delete_project(key),
    do: update_in_file(project_settings_path(), &Map.delete(&1, to_string(key)))

  defp set_in_file(path, key, value),
    do: update_in_file(path, &Map.put(&1, to_string(key), value))

  defp update_in_file(path, fun) do
    case load_json_for_write(path) do
      {:ok, settings} ->
        # Register the internal write BEFORE touching the file so the watcher
        # can never observe the change in the gap before suppression lands.
        OptimalSystemAgent.Settings.Watcher.note_internal_write(path)
        result = write_json(path, fun.(settings))
        reset_cache()
        result

      {:error, :corrupt} ->
        Logger.warning(
          "[settings] Refusing to overwrite corrupt settings file #{path} — fix or delete it first"
        )

        {:error, :corrupt_settings_file}
    end
  end

  @doc "Get all settings merged (for /settings API endpoint)."
  def all, do: merged()

  @doc "Get settings from a specific layer."
  def layer(:user), do: load_json(@user_settings)
  def layer(:project), do: load_json(project_settings_path())
  def layer(:local), do: load_json(local_settings_path())
  def layer(:session), do: get_all_session()

  def layer(:flag) do
    case flag_settings_path() do
      nil -> %{}
      path -> load_json(path)
    end
  end

  @doc """
  Merge `"hooks"` config across ALL settings layers by CONCATENATION.

  Unlike `get(:hooks)` (which returns only the highest-priority layer's map,
  shadowing every other source), this concatenates each event's hook list
  across user → project → local → session so hooks configured in multiple
  files all fire. Duplicate hook entries are removed.
  """
  def get_merged_hooks do
    # Workspace trust (CC parity, WS15 enforcement): checked-in project
    # settings are workspace-supplied executable config — their hooks stay
    # inert until the user accepts trust for the cwd (/trust accept or the
    # trust dialog). User/local/flag/session layers are authored on this
    # machine and always apply.
    project_layers = if project_trusted?(), do: [layer(:project)], else: []

    ([layer(:user)] ++ project_layers ++ [layer(:local), layer(:flag), layer(:session)])
    |> Enum.map(&layer_hooks/1)
    |> Enum.reduce(%{}, fn hooks, acc ->
      Map.merge(acc, hooks, fn _event, a, b -> a ++ b end)
    end)
    |> Map.new(fn {event, list} -> {event, Enum.uniq(list)} end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp get_all_session do
    try do
      :ets.match(:osa_settings, {{:session, :"$1"}, :"$2"})
      |> Enum.reduce(%{}, fn [key, value], acc ->
        Map.put(acc, to_string(key), value)
      end)
    rescue
      _ -> %{}
    end
  end

  # True when the current working directory has accepted workspace trust.
  # Fails CLOSED (false — project hooks stay inert) on any Trust error so a
  # crash can never widen the executable-config surface.
  defp project_trusted? do
    OptimalSystemAgent.Workspace.Trust.trusted?(OptimalSystemAgent.Workspace.Cwd.get())
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp layer_hooks(layer) when is_map(layer) do
    case Map.get(layer, "hooks") do
      hooks when is_map(hooks) ->
        Map.new(hooks, fn {event, list} -> {to_string(event), List.wrap(list)} end)

      _ ->
        %{}
    end
  end

  defp layer_hooks(_), do: %{}

  # Presence-aware read for WRITE paths: distinguishes a missing/empty file
  # (fresh start → {:ok, %{}}) from an existing-but-unparseable one (refuse
  # to clobber → {:error, :corrupt}). Non-map top-level JSON is also corrupt.
  defp load_json_for_write(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            {:ok, map}

          _ ->
            if String.trim(content) == "", do: {:ok, %{}}, else: {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} ->
        {:error, :corrupt}
    end
  end

  defp project_settings_path do
    Path.join(OptimalSystemAgent.Workspace.Cwd.get(), ".osa/settings.json")
  rescue
    _ -> ".osa/settings.json"
  end

  defp local_settings_path do
    Path.join(OptimalSystemAgent.Workspace.Cwd.get(), ".osa/settings.local.json")
  rescue
    _ -> ".osa/settings.local.json"
  end

  defp flag_settings_path do
    Application.get_env(:optimal_system_agent, :settings_flag_path) ||
      System.get_env("OSA_SETTINGS")
  end

  # Cached file read: `{path, sig, map}` rows in @cache_table, where sig is
  # `{mtime, size}`. A stat is much cheaper than read+decode; reset_cache/0
  # (watcher / internal writes) clears every row at once.
  defp load_json(path) do
    case file_sig(path) do
      nil -> %{}
      sig -> cached_parse(path, sig)
    end
  rescue
    _ -> %{}
  end

  defp file_sig(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _ -> nil
    end
  end

  defp cached_parse(path, sig) do
    case :ets.lookup(@cache_table, path) do
      [{^path, ^sig, map}] -> map
      _ -> parse_and_cache(path, sig)
    end
  rescue
    # Cache table not created yet (early boot) — read uncached.
    _ -> parse_json_file(path)
  end

  defp parse_and_cache(path, sig) do
    map = parse_json_file(path)

    try do
      :ets.insert(@cache_table, {path, sig, map})
    rescue
      _ -> :ok
    end

    map
  end

  defp parse_json_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp write_json(path, data) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.write!(path, Jason.encode!(data, pretty: true))
    :ok
  rescue
    e ->
      Logger.warning("[settings] Failed to write #{path}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
