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

  @doc "Save session state to disk. `working_dir` tags the session to a folder so it can be resumed there."
  def save(session_id, messages, working_dir \\ nil) when is_list(messages) do
    File.mkdir_p!(@sessions_dir)
    path = session_path(session_id)

    data = %{
      session_id: session_id,
      working_dir: normalize_dir(working_dir),
      message_count: length(messages),
      saved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      messages: sanitize_messages(messages)
    }

    case Jason.encode(data) do
      {:ok, json} ->
        # Atomic write-then-rename: a crash mid-write can never truncate the
        # session JSON, and overlapping auto_saves (which run outside the single
        # Loop GenServer) resolve to a clean last-writer-wins instead of
        # interleaving into corrupt bytes.
        tmp = path <> ".tmp"
        File.write!(tmp, json)
        File.rename!(tmp, path)
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
          {:ok, %{"messages" => messages}} when is_list(messages) ->
            # Skip-and-keep-going: one malformed (non-map) turn must not fail the
            # whole session resume. Bound key→atom conversion with
            # to_existing_atom so a tampered file cannot exhaust the atom table.
            restored =
              messages
              |> Enum.filter(&is_map/1)
              |> Enum.map(fn m -> Map.new(m, fn {k, v} -> {safe_key(k), v} end) end)

            {:ok, restored}

          {:ok, _} ->
            # Decoded but no usable messages list — treat as an empty session
            # rather than crashing the resume.
            {:ok, []}

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

  @doc """
  List recent saved sessions. Pass `working_dir:` to only return sessions for
  that folder (directory-scoped, Claude Code style).
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_sessions)
    filter_dir = normalize_dir(Keyword.get(opts, :working_dir))

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
            working_dir: read_working_dir(path),
            size: stat.size,
            modified_at: stat.mtime
          }
        end)
        |> then(fn sessions ->
          if filter_dir,
            do: Enum.filter(sessions, &(&1.working_dir == filter_dir)),
            else: sessions
        end)
        |> Enum.sort_by(& &1.modified_at, {:desc, NaiveDateTime})
        |> Enum.take(limit)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  @doc "Return the most recently saved session_id for a folder, or nil. Powers per-directory resume."
  def find_latest_for_dir(working_dir) do
    case list(working_dir: working_dir, limit: 1) do
      [%{session_id: id} | _] -> id
      _ -> nil
    end
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
          save(session_id, state.messages, Map.get(state, :working_dir))
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

  # Bounded key→atom conversion. Message maps only ever use a small fixed set of
  # atom keys, so to_existing_atom preserves behavior for legitimate files while
  # capping atom-table growth on a malformed/tampered session file.
  defp safe_key(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> k
    end
  end

  defp safe_key(k), do: k

  # Canonical form for a working dir so the same folder always matches (expand ~,
  # strip trailing slash). nil stays nil.
  defp normalize_dir(nil), do: nil

  defp normalize_dir(dir) when is_binary(dir) do
    case String.trim(dir) do
      "" -> nil
      d -> d |> Path.expand() |> String.trim_trailing("/")
    end
  end

  defp normalize_dir(_), do: nil

  # Cheaply read just the working_dir field from a saved session file.
  defp read_working_dir(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{"working_dir" => dir}} <- Jason.decode(json) do
      dir
    else
      _ -> nil
    end
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
