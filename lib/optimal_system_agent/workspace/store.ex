defmodule OptimalSystemAgent.Workspace.Store do
  @moduledoc """
  SQLite persistence for workspaces and task journals.

  Tables:
  - `workspaces`    — one row per workspace: id, name, project_path, state_json
  - `task_journals` — append-only log of all task state changes per workspace

  Uses Store.Repo (ecto_sqlite3) following the same raw-query pattern as
  Agent.Scheduler.SQLiteStore. No Ecto schemas — JSON payloads for flexibility.

  All table creation is idempotent via `CREATE TABLE IF NOT EXISTS`.
  """

  require Logger
  alias OptimalSystemAgent.Store.Repo

  @create_workspaces """
  CREATE TABLE IF NOT EXISTS workspaces (
    id           TEXT PRIMARY KEY,
    name         TEXT NOT NULL DEFAULT '',
    project_path TEXT NOT NULL DEFAULT '',
    state_json   TEXT NOT NULL DEFAULT '{}',
    created_at   TEXT NOT NULL DEFAULT '',
    updated_at   TEXT NOT NULL DEFAULT ''
  )
  """

  @create_task_journals """
  CREATE TABLE IF NOT EXISTS task_journals (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id TEXT NOT NULL,
    task_id      TEXT NOT NULL DEFAULT '',
    agent_id     TEXT NOT NULL DEFAULT '',
    action       TEXT NOT NULL DEFAULT '',
    details_json TEXT NOT NULL DEFAULT '{}',
    inserted_at  TEXT NOT NULL DEFAULT ''
  )
  """

  @create_journals_idx """
  CREATE INDEX IF NOT EXISTS task_journals_workspace_id
    ON task_journals (workspace_id, inserted_at)
  """

  # ── Bootstrap ─────────────────────────────────────────────────────────────

  @doc "Create tables and indexes. Called once at application start."
  @spec init() :: :ok | {:error, term()}
  def init do
    with {:ok, _} <- Repo.query(@create_workspaces),
         {:ok, _} <- Repo.query(@create_task_journals),
         {:ok, _} <- Repo.query(@create_journals_idx) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[Workspace.Store] Table init failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Workspace.Store] init/0 exception: #{Exception.message(e)}")
      {:error, :repo_unavailable}
  end

  # ── Workspace CRUD ────────────────────────────────────────────────────────

  @doc """
  Upsert a workspace record. `workspace` must include `:id`, `:name`,
  `:project_path`, and `:state` (the full state map that gets JSON-encoded).
  """
  @spec save_workspace(map()) :: :ok | {:error, term()}
  def save_workspace(%{id: id} = workspace) do
    now = utc_now()
    name = Map.get(workspace, :name, "")
    project_path = Map.get(workspace, :project_path, "")
    state_json = Jason.encode!(Map.get(workspace, :state, %{}))

    sql = """
    INSERT INTO workspaces (id, name, project_path, state_json, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      name         = excluded.name,
      project_path = excluded.project_path,
      state_json   = excluded.state_json,
      updated_at   = excluded.updated_at
    """

    case Repo.query(sql, [id, name, project_path, state_json, now, now]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Load a workspace by id.
  Returns `{:ok, map()}` where the map contains `:id`, `:name`,
  `:project_path`, `:state`, `:created_at`, `:updated_at`, or `{:error, :not_found}`.
  """
  @spec load_workspace(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def load_workspace(id) do
    sql = "SELECT id, name, project_path, state_json, created_at, updated_at FROM workspaces WHERE id = ?"

    case Repo.query(sql, [id]) do
      {:ok, %{rows: [[wid, name, path, state_json, created_at, updated_at]]}} ->
        state = decode_json(state_json, %{})

        {:ok,
         %{
           id: wid,
           name: name,
           project_path: path,
           state: state,
           created_at: created_at,
           updated_at: updated_at
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "List all workspaces as lightweight summaries (no full state)."
  @spec list_workspaces() :: [map()]
  def list_workspaces do
    sql = "SELECT id, name, project_path, created_at, updated_at FROM workspaces ORDER BY updated_at DESC"

    case Repo.query(sql) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, name, path, created_at, updated_at] ->
          %{
            id: id,
            name: name,
            project_path: path,
            created_at: created_at,
            updated_at: updated_at
          }
        end)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Delete a workspace and all its journal entries."
  @spec delete_workspace(String.t()) :: :ok | {:error, term()}
  def delete_workspace(id) do
    with {:ok, _} <- Repo.query("DELETE FROM task_journals WHERE workspace_id = ?", [id]),
         {:ok, _} <- Repo.query("DELETE FROM workspaces WHERE id = ?", [id]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Task Journal ──────────────────────────────────────────────────────────

  @doc """
  Append a journal entry.

  `entry` must include:
  - `:workspace_id` — String
  - `:task_id`      — String
  - `:agent_id`     — String
  - `:action`       — atom or string (:created | :assigned | :started | :paused | :completed | :failed | :reassigned)
  - `:details`      — map (optional, defaults to `%{}`)
  """
  @spec append_journal(map()) :: :ok | {:error, term()}
  def append_journal(%{workspace_id: workspace_id} = entry) do
    now = utc_now()
    task_id = Map.get(entry, :task_id, "")
    agent_id = Map.get(entry, :agent_id, "")
    action = entry |> Map.get(:action, :unknown) |> to_string()
    details_json = Jason.encode!(Map.get(entry, :details, %{}))

    sql = """
    INSERT INTO task_journals (workspace_id, task_id, agent_id, action, details_json, inserted_at)
    VALUES (?, ?, ?, ?, ?, ?)
    """

    case Repo.query(sql, [workspace_id, task_id, agent_id, action, details_json, now]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Query journal entries for a workspace.

  ## Options
  - `:task_id`   — filter by task id
  - `:agent_id`  — filter by agent id
  - `:action`    — filter by action atom or string
  - `:since`     — ISO8601 lower bound on inserted_at
  - `:until`     — ISO8601 upper bound on inserted_at
  - `:limit`     — max rows (default: 500)
  """
  @spec query_journal(String.t(), keyword()) :: [map()]
  def query_journal(workspace_id, opts \\ []) do
    conditions = ["workspace_id = ?"]
    params = [workspace_id]

    {conditions, params} =
      opts
      |> Enum.reduce({conditions, params}, fn
        {:task_id, v}, {c, p} -> {c ++ ["task_id = ?"], p ++ [v]}
        {:agent_id, v}, {c, p} -> {c ++ ["agent_id = ?"], p ++ [v]}
        {:action, v}, {c, p} -> {c ++ ["action = ?"], p ++ [to_string(v)]}
        {:since, v}, {c, p} -> {c ++ ["inserted_at >= ?"], p ++ [v]}
        {:until, v}, {c, p} -> {c ++ ["inserted_at <= ?"], p ++ [v]}
        _, acc -> acc
      end)

    limit = Keyword.get(opts, :limit, 500)
    where = Enum.join(conditions, " AND ")
    sql = "SELECT workspace_id, task_id, agent_id, action, details_json, inserted_at FROM task_journals WHERE #{where} ORDER BY inserted_at ASC LIMIT #{limit}"

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [wid, task_id, agent_id, action, details_json, inserted_at] ->
          %{
            workspace_id: wid,
            task_id: task_id,
            agent_id: agent_id,
            action: String.to_existing_atom(action),
            details: decode_json(details_json, %{}),
            inserted_at: inserted_at
          }
        end)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp utc_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> default
    end
  end

  defp decode_json(_, default), do: default
end
