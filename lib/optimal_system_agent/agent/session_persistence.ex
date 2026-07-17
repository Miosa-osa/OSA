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

    data =
      %{
        session_id: session_id,
        working_dir: normalize_dir(working_dir),
        message_count: length(messages),
        saved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        messages: sanitize_messages(messages)
      }
      # Preserve user-set metadata (title/tags from /rename and /tag) so an
      # auto_save that only carries messages never clobbers it.
      |> merge_preserved_metadata(path)

    case Jason.encode(data) do
      {:ok, json} ->
        # Atomic write-then-rename: a crash mid-write can never truncate the
        # session JSON, and overlapping auto_saves (which run outside the single
        # Loop GenServer) resolve to a clean last-writer-wins instead of
        # interleaving into corrupt bytes.
        # Unique temp path per writer: concurrent auto_saves each own their own
        # temp inode so rename(2) gives true whole-file last-writer-wins with no
        # interleaving (a shared ".tmp" would be re-truncated mid-flight and torn).
        tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
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
        |> Enum.flat_map(fn file ->
          path = Path.join(@sessions_dir, file)
          session_id = String.trim_trailing(file, ".json")

          # Per-file try: a session file removed/renamed by a concurrent writer
          # (e.g. a live session auto-saving) must skip that one entry, not wipe
          # the whole listing.
          case File.stat(path) do
            {:ok, stat} ->
              meta = read_meta(path)

              [
                %{
                  session_id: session_id,
                  working_dir: meta.working_dir,
                  title: meta.title,
                  tags: meta.tags,
                  size: stat.size,
                  modified_at: to_naive(stat.mtime)
                }
              ]

            {:error, _} ->
              []
          end
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

  @doc """
  Merge friendly metadata (e.g. `%{title: ..., tags: [...]}`) into a saved
  session record. Creates the record if none exists yet so `/rename` and `/tag`
  work before the first message is saved. Returns `:ok` or `{:error, reason}`.
  """
  def update_metadata(session_id, fields) when is_map(fields) do
    File.mkdir_p!(@sessions_dir)
    path = session_path(session_id)

    existing =
      case File.read(path) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, data} when is_map(data) -> data
            _ -> base_record(session_id)
          end

        _ ->
          base_record(session_id)
      end

    string_fields = Map.new(fields, fn {k, v} -> {to_string(k), v} end)
    write_json(path, Map.merge(existing, string_fields))
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Read a single session's metadata (title, tags, working_dir)."
  def get_metadata(session_id) do
    read_meta(session_path(session_id))
  end

  @doc """
  Persist the per-session message queue (queued-but-unsent user messages).

  This is a durable *mirror* of the in-memory `MessageQueue` — the live queue
  stays authoritative and fast, and this write lets queued messages survive a
  backend restart. `messages` is a plain list of strings. An empty list clears
  the mirror. Creates the session record if none exists yet.
  """
  @spec save_queue(String.t(), [String.t()]) :: :ok | {:error, term()}
  def save_queue(session_id, messages) when is_list(messages) do
    strings = for m <- messages, is_binary(m), do: m
    update_metadata(session_id, %{queued_messages: strings})
  end

  @doc "Load the persisted per-session message queue as a list of strings ([] if none)."
  @spec load_queue(String.t()) :: [String.t()]
  def load_queue(session_id) do
    with {:ok, json} <- File.read(session_path(session_id)),
         {:ok, %{"queued_messages" => q}} when is_list(q) <- Jason.decode(json) do
      for m <- q, is_binary(m), do: m
    else
      _ -> []
    end
  rescue
    _ -> []
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

  # Cheaply read display metadata (working_dir, title, tags) from a session file.
  defp read_meta(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} when is_map(data) <- Jason.decode(json) do
      %{
        working_dir: data["working_dir"],
        title: data["title"],
        tags: normalize_tags(data["tags"])
      }
    else
      _ -> %{working_dir: nil, title: nil, tags: []}
    end
  end

  defp normalize_tags(tags) when is_list(tags), do: tags
  defp normalize_tags(_), do: []

  # File.stat mtime is an Erlang datetime tuple ({{y,m,d},{h,mi,s}}); convert to
  # NaiveDateTime so the {:desc, NaiveDateTime} sort (and callers that render the
  # date) work. Previously the raw tuple made the sort raise, and the blanket
  # rescue turned the whole listing into [] — leaving /resume permanently empty.
  defp to_naive({{_, _, _}, {_, _, _}} = erl_dt) do
    case NaiveDateTime.from_erl(erl_dt) do
      {:ok, ndt} -> ndt
      _ -> ~N[1970-01-01 00:00:00]
    end
  end

  defp to_naive(%NaiveDateTime{} = ndt), do: ndt
  defp to_naive(_), do: ~N[1970-01-01 00:00:00]

  # A minimal record used when metadata is set before any messages are saved.
  defp base_record(session_id) do
    %{
      "session_id" => session_id,
      "working_dir" => nil,
      "message_count" => 0,
      "saved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "messages" => []
    }
  end

  # Read the title/tags from an existing record (if any) and re-apply them onto
  # a freshly-built save payload, keeping them stable across message-only saves.
  defp merge_preserved_metadata(data, path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, existing} when is_map(existing) ->
            Enum.reduce(["title", "tags", "queued_messages"], data, fn key, acc ->
              case Map.get(existing, key) do
                nil -> acc
                val -> Map.put(acc, key, val)
              end
            end)

          _ ->
            data
        end

      _ ->
        data
    end
  end

  # Atomic JSON write (temp-then-rename), shared by save/3 and update_metadata/2.
  defp write_json(path, data) do
    case Jason.encode(data) do
      {:ok, json} ->
        tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))
        File.write!(tmp, json)
        File.rename!(tmp, path)
        :ok

      {:error, reason} ->
        {:error, reason}
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
