defmodule OptimalSystemAgent.Settings do
  @moduledoc """
  Multi-layer settings cascade.

  Settings are resolved through 4 layers (highest priority last):

  1. **User** — `~/.osa/settings.json` (global user preferences)
  2. **Project** — `.osa/settings.json` (checked into repo, shared with team)
  3. **Local** — `.osa/settings.local.json` (gitignored, per-developer overrides)
  4. **Session** — in-memory only, set via API or CLI commands

  Each layer can override any key from the layer above. The resolution
  is lazy — settings are read at call time, not cached at boot.
  """
  require Logger

  @user_settings Path.expand("~/.osa/settings.json")

  @doc """
  Get a setting by key, resolved through the cascade.

  Resolution is presence-based (`Map.fetch` per layer), so an explicit `false`
  or `null` in a higher-priority layer is honored instead of falling through
  to a lower layer or the default (CC `updateSettingsForSource` semantics).
  """
  def get(key, default \\ nil) do
    with :error <- fetch_session(key),
         :error <- Map.fetch(load_json(local_settings_path()), to_string(key)),
         :error <- Map.fetch(load_json(project_settings_path()), to_string(key)),
         :error <- Map.fetch(load_json(@user_settings), to_string(key)) do
      default
    else
      {:ok, value} -> value
    end
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

  defp set_in_file(path, key, value) do
    case load_json_for_write(path) do
      {:ok, settings} ->
        write_json(path, Map.put(settings, to_string(key), value))

      {:error, :corrupt} ->
        Logger.warning(
          "[settings] Refusing to overwrite corrupt settings file #{path} — fix or delete it first"
        )

        {:error, :corrupt_settings_file}
    end
  end

  @doc "Get all settings merged (for /settings API endpoint)."
  def all do
    user = load_json(@user_settings)
    project = load_json(project_settings_path())
    local = load_json(local_settings_path())
    session = get_all_session()

    user
    |> Map.merge(project)
    |> Map.merge(local)
    |> Map.merge(session)
  end

  @doc "Get settings from a specific layer."
  def layer(:user), do: load_json(@user_settings)
  def layer(:project), do: load_json(project_settings_path())
  def layer(:local), do: load_json(local_settings_path())
  def layer(:session), do: get_all_session()

  @doc """
  Merge `"hooks"` config across ALL settings layers by CONCATENATION.

  Unlike `get(:hooks)` (which returns only the highest-priority layer's map,
  shadowing every other source), this concatenates each event's hook list
  across user → project → local → session so hooks configured in multiple
  files all fire. Duplicate hook entries are removed.
  """
  def get_merged_hooks do
    [layer(:user), layer(:project), layer(:local), layer(:session)]
    |> Enum.map(&layer_hooks/1)
    |> Enum.reduce(%{}, fn hooks, acc ->
      Map.merge(acc, hooks, fn _event, a, b -> a ++ b end)
    end)
    |> Map.new(fn {event, list} -> {event, Enum.uniq(list)} end)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp fetch_session(key) do
    try do
      case :ets.lookup(:osa_settings, {:session, key}) do
        [{{:session, ^key}, value}] -> {:ok, value}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

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
    Path.join(File.cwd!(), ".osa/settings.json")
  rescue
    _ -> ".osa/settings.json"
  end

  defp local_settings_path do
    Path.join(File.cwd!(), ".osa/settings.local.json")
  rescue
    _ -> ".osa/settings.local.json"
  end

  defp load_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  rescue
    _ -> %{}
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
