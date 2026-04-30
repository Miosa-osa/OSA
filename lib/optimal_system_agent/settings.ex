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

  @doc "Get a setting by key, resolved through the cascade."
  def get(key, default \\ nil) do
    get_session(key) ||
      get_local(key) ||
      get_project(key) ||
      get_user(key) ||
      default
  end

  @doc "Set a session-level setting (in-memory only, not persisted)."
  def set_session(key, value) do
    try do
      :ets.insert(:osa_settings, {{:session, key}, value})
    rescue
      _ -> :ok
    end
  end

  @doc "Set a user-level setting (persisted to ~/.osa/settings.json)."
  def set_user(key, value) do
    settings = load_json(@user_settings)
    updated = Map.put(settings, to_string(key), value)
    write_json(@user_settings, updated)
  end

  @doc "Set a project-level setting (persisted to .osa/settings.json)."
  def set_project(key, value) do
    path = project_settings_path()
    settings = load_json(path)
    updated = Map.put(settings, to_string(key), value)
    write_json(path, updated)
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

  # ── Private ──────────────────────────────────────────────────────────

  defp get_session(key) do
    try do
      case :ets.lookup(:osa_settings, {:session, key}) do
        [{{:session, ^key}, value}] -> value
        _ -> nil
      end
    rescue
      _ -> nil
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

  defp get_local(key), do: Map.get(load_json(local_settings_path()), to_string(key))
  defp get_project(key), do: Map.get(load_json(project_settings_path()), to_string(key))
  defp get_user(key), do: Map.get(load_json(@user_settings), to_string(key))

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
