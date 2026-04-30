defmodule OptimalSystemAgent.Agent.Scheduler.SQLiteStore do
  @moduledoc """
  SQLite-backed persistence for scheduler cron jobs via Store.Repo (ecto_sqlite3).
  Jobs are stored as JSON payloads — no Ecto schema required.
  """
  require Logger

  alias OptimalSystemAgent.Store.Repo

  @create_table """
  CREATE TABLE IF NOT EXISTS scheduler_jobs (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL DEFAULT '',
    cron_expr  TEXT NOT NULL DEFAULT '',
    payload    TEXT NOT NULL DEFAULT '{}',
    enabled    INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT ''
  )
  """

  def init do
    case Repo.query(@create_table) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Scheduler.SQLiteStore] Table init failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Scheduler.SQLiteStore] init/0 exception: #{Exception.message(e)}")
      {:error, :repo_unavailable}
  end

  def save_job(%{"id" => id} = job) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    payload = Jason.encode!(job)
    enabled = if Map.get(job, "enabled", true), do: 1, else: 0
    name = Map.get(job, "name", "")
    cron_expr = Map.get(job, "cron", "")

    sql = """
    INSERT INTO scheduler_jobs (id, name, cron_expr, payload, enabled, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      name = excluded.name,
      cron_expr = excluded.cron_expr,
      payload = excluded.payload,
      enabled = excluded.enabled,
      updated_at = excluded.updated_at
    """

    case Repo.query(sql, [id, name, cron_expr, payload, enabled, now, now]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def load_all_jobs do
    case Repo.query("SELECT payload, enabled FROM scheduler_jobs") do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [payload_json, enabled_int] ->
          case Jason.decode(payload_json) do
            {:ok, job} -> Map.put(job, "enabled", enabled_int == 1)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  def delete_job(id) do
    case Repo.query("DELETE FROM scheduler_jobs WHERE id = ?", [id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def update_job(id, changes) when is_map(changes) do
    case Repo.query("SELECT payload FROM scheduler_jobs WHERE id = ?", [id]) do
      {:ok, %{rows: [[payload_json]]}} ->
        with {:ok, existing} <- Jason.decode(payload_json) do
          merged = Map.merge(existing, changes)
          save_job(Map.put(merged, "id", id))
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
