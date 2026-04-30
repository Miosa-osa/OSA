defmodule OptimalSystemAgent.Agent.SessionPersistence do
  @moduledoc """
  Full session state persistence for resume/continue.

  Saves the complete conversation history (messages) to disk so sessions
  can be resumed across restarts. Uses JSON files under ~/.osa/sessions/.

  This is different from session_transcript (FTS search) — this stores the
  actual message list needed to restore agent state.
  """
  require Logger

  @sessions_dir Path.expand("~/.osa/sessions")
  @max_sessions 50

  @doc "Save session state to disk."
  def save(session_id, messages) when is_list(messages) do
    File.mkdir_p!(@sessions_dir)
    path = session_path(session_id)

    data = %{
      session_id: session_id,
      message_count: length(messages),
      saved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      messages: sanitize_messages(messages)
    }

    case Jason.encode(data) do
      {:ok, json} ->
        File.write!(path, json)
        Logger.debug("[session_persist] Saved #{length(messages)} messages for #{session_id}")
        :ok

      {:error, reason} ->
        Logger.warning("[session_persist] Failed to encode session: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[session_persist] Save failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "Load session state from disk."
  def load(session_id) do
    path = session_path(session_id)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"messages" => messages}} ->
            restored =
              Enum.map(messages, fn msg ->
                msg
                |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
              end)

            {:ok, restored}

          {:error, reason} ->
            {:error, "JSON decode failed: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "List recent saved sessions."
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_sessions)

    case File.ls(@sessions_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn file ->
          path = Path.join(@sessions_dir, file)
          session_id = String.trim_trailing(file, ".json")
          stat = File.stat!(path)

          %{
            session_id: session_id,
            size: stat.size,
            modified_at: stat.mtime
          }
        end)
        |> Enum.sort_by(& &1.modified_at, {:desc, NaiveDateTime})
        |> Enum.take(limit)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Delete a saved session."
  def delete(session_id) do
    path = session_path(session_id)
    File.rm(path)
  end

  @doc "Auto-save session state (called from hooks)."
  def auto_save(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] ->
        try do
          state = :sys.get_state(pid)
          save(session_id, state.messages)
        rescue
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp session_path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join(@sessions_dir, "#{safe_id}.json")
  end

  # Strip non-serializable data from messages
  defp sanitize_messages(messages) do
    Enum.map(messages, fn msg ->
      msg
      |> Map.delete(:__order)
      |> Map.delete(:__struct__)
      |> Map.new(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end)
  end
end
