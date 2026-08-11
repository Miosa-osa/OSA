defmodule OptimalSystemAgent.Agent.Tasks.Persistence do
  @moduledoc """
  Unified persistence layer for the Agent.Tasks subsystem.

  Provides two storage backends:
  - JSON files for Workflow (one file per workflow: ~/.osa/workflows/{id}.json)
  - JSON files for Tracker tasks (per-session: ~/.osa/sessions/{sid}/tasks.json)

  Both use atomic .tmp → rename writes to prevent corruption.
  """

  require Logger
  alias OptimalSystemAgent.System.AtomicFile

  # ── Workflow Persistence ─────────────────────────────────────────────

  @doc "Persist a serialized workflow map to disk."
  @spec save_workflow(String.t(), map()) :: :ok
  def save_workflow(dir, %{"id" => id} = data) do
    path = Path.join(dir, "#{id}.json")

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        :ok

      {:error, reason} ->
        Logger.error("[Tasks.Persistence] Failed to encode workflow #{id}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.error(
        "[Tasks.Persistence] Failed to write workflow #{inspect(dir)}: #{Exception.message(e)}"
      )

      :ok
  end

  @doc "Load all workflow JSON files from a directory. Returns a map of id => raw data."
  @spec load_all_workflows(String.t()) :: [map()]
  def load_all_workflows(dir) do
    if File.exists?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.flat_map(fn filename ->
        path = Path.join(dir, filename)

        case load_json_file(path) do
          {:ok, data} ->
            [data]

          {:error, reason} ->
            Logger.warning("[Tasks.Persistence] Skipping workflow file #{filename}: #{reason}")
            []
        end
      end)
    else
      []
    end
  rescue
    e ->
      Logger.warning(
        "[Tasks.Persistence] Failed to load workflows from #{dir}: #{Exception.message(e)}"
      )

      []
  end

  # ── Tracker Persistence ──────────────────────────────────────────────

  @doc "Persist a list of serialized task maps for a session."
  @spec save_tasks(String.t(), [map()]) :: :ok
  def save_tasks(session_id, tasks) do
    path = tasks_path(session_id)
    dir = Path.dirname(path)

    try do
      File.mkdir_p!(dir)
      json = Jason.encode!(tasks, pretty: true)
      AtomicFile.write!(path, json)
      :ok
    rescue
      e ->
        Logger.error(
          "[Tasks.Persistence] Persist failed for session #{session_id}: #{inspect(e)}"
        )

        :ok
    end
  end

  @doc "Load serialized task list for a session. Returns [] if not found or corrupt."
  @spec load_tasks(String.t()) :: [map()]
  def load_tasks(session_id) do
    path = tasks_path(session_id)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Returns the default workflows directory."
  @spec workflows_dir() :: String.t()
  def workflows_dir do
    Application.get_env(:optimal_system_agent, :workflows_dir, "~/.osa/workflows")
    |> Path.expand()
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp tasks_path(session_id) do
    base = System.get_env("OSA_HOME") || Path.expand("~/.osa")
    Path.join([base, "sessions", session_id, "tasks.json"])
  end

  defp load_json_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, data}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
