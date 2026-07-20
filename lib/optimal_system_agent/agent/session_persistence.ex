defmodule OptimalSystemAgent.Agent.SessionPersistence do
  @moduledoc """
  Full session state persistence for resume/continue.

  Saves the complete conversation history (messages) to disk so sessions
  can be resumed across restarts. Uses JSON files under ~/.osa/sessions/.

  This is different from session_transcript (FTS search) — this stores the
  actual message list needed to restore agent state.

  ## Two-log persistence

  Every save maintains two files per session, mirroring grok-build's split:

    * `<id>.json` — the **mutable**, compaction-pruned transcript. Rewritten
      crash-atomically (temp + rename) each turn; this is the list `/resume`
      reads back and replays. Compaction shrinks it.
    * `<id>.updates.jsonl` — the **immutable**, append-only event log. Only ever
      appended to (see `Jsonl` for the self-healing/locked append and
      corruption-tolerant read), so it is the full source of truth for
      replay/rewind and is NEVER touched by compaction.

  The split means compaction (which rewrites `<id>.json`) and the event history
  can never corrupt each other. `load/1` returns the mutable transcript for
  resume; `load_events/1` returns the immutable stream for full-history replay.
  Sessions saved before this feature simply have no `.updates.jsonl` yet and
  load exactly as before.
  """
  require Logger

  alias OptimalSystemAgent.Agent.SessionPersistence.Jsonl
  alias OptimalSystemAgent.ConfigFile

  # Runtime-resolved so a prebuilt release uses the END USER's home, not the CI
  # runner's baked-in path. Resolved on every call via ConfigFile.config_dir/0.
  defp sessions_dir, do: Path.join(ConfigFile.config_dir(), "sessions")

  @max_sessions 50

  @doc "Save session state to disk. `working_dir` tags the session to a folder so it can be resumed there."
  def save(session_id, messages, working_dir \\ nil) when is_list(messages) do
    File.mkdir_p!(sessions_dir())
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

        # Two-log persistence: alongside the mutable, compaction-pruned transcript
        # written above (<id>.json), append any newly-seen messages to the
        # IMMUTABLE append-only event log (<id>.updates.jsonl). Compaction shrinks
        # `messages` and rewrites <id>.json, but the immutable log is only ever
        # appended to — it stays the full source of truth for replay/rewind.
        # Best-effort: a failure here never breaks the (already-committed) save.
        append_updates(session_id, messages)

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

  @doc """
  Load session state from disk.

  If `<id>.json` (the mutable transcript) is missing or corrupt, this falls
  back to rebuilding from `<id>.updates.jsonl` (the immutable, append-only
  event log via `load_events/1`) before giving up. The jsonl log is
  corruption-tolerant (torn lines are skipped, not fatal), so a torn `.json`
  next to an intact `.updates.jsonl` no longer means permanent amnesia.
  """
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
            load_from_events_or(session_id, {:error, "JSON decode failed: #{inspect(reason)}"})
        end

      {:error, :enoent} ->
        load_from_events_or(session_id, {:error, :not_found})

      {:error, reason} ->
        load_from_events_or(session_id, {:error, reason})
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Fallback used by load/1 when `<id>.json` is missing or unreadable/corrupt:
  # rebuild the transcript from the immutable `<id>.updates.jsonl` event log
  # instead of surrendering to `fallback` (the original error). Returns the
  # rebuilt messages (possibly []) when the event log has anything to offer,
  # otherwise the original error so callers can't mistake "never saved" for
  # "recovered empty".
  defp load_from_events_or(session_id, fallback) do
    case Jsonl.read(updates_path(session_id)) do
      {:ok, [], 0} ->
        fallback

      {:ok, _events, _skipped} ->
        restored =
          session_id
          |> load_events()
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn m -> Map.new(m, fn {k, v} -> {safe_key(k), v} end) end)

        Logger.warning(
          "[session_persist] #{session_id}: <id>.json missing/corrupt, rebuilt " <>
            "#{length(restored)} message(s) from <id>.updates.jsonl"
        )

        {:ok, restored}

      _ ->
        fallback
    end
  end

  @doc """
  List recent saved sessions. Pass `working_dir:` to only return sessions for
  that folder (directory-scoped, Claude Code style).
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_sessions)
    filter_dir = normalize_dir(Keyword.get(opts, :working_dir))

    case File.ls(sessions_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(fn file ->
          path = Path.join(sessions_dir(), file)
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

  @doc "Delete a saved session (mutable transcript + immutable event log sidecars)."
  def delete(session_id) do
    path = session_path(session_id)
    # Remove the immutable event log and its lock/quarantine sidecars too, so a
    # deleted session leaves nothing behind.
    Jsonl.delete(updates_path(session_id))
    _ = File.rm(path <> ".corrupt")
    File.rm(path)
  end

  @doc """
  Delete saved session files older than the `cleanupPeriodDays` retention window
  (CC-parity; default 30). Called once at startup. A value of `0` purges EVERY
  saved session (retention disabled). Non-positive/invalid values fall back to
  the 30-day default. Best-effort: never raises. Returns `{:ok, removed_count}`.
  """
  @spec purge_expired() :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired do
    days = retention_days()
    cutoff = System.system_time(:second) - days * 86_400

    case File.ls(sessions_dir()) do
      {:ok, files} ->
        removed =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.count(fn file ->
            path = Path.join(sessions_dir(), file)

            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime}} when days == 0 or mtime < cutoff ->
                # Purge the immutable event log + sidecars alongside the mutable
                # transcript so an expired session leaves no orphaned files.
                session_id = String.trim_trailing(file, ".json")
                Jsonl.delete(updates_path(session_id))
                _ = File.rm(path <> ".corrupt")
                File.rm(path) == :ok

              _ ->
                false
            end
          end)

        if removed > 0 do
          Logger.info("[session_persist] Purged #{removed} session(s) older than #{days}d")
        end

        {:ok, removed}

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp retention_days do
    case OptimalSystemAgent.Settings.get("cleanupPeriodDays", 30) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 30
    end
  end

  @doc """
  Merge friendly metadata (e.g. `%{title: ..., tags: [...]}`) into a saved
  session record. Creates the record if none exists yet so `/rename` and `/tag`
  work before the first message is saved. Returns `:ok` or `{:error, reason}`.
  """
  def update_metadata(session_id, fields) when is_map(fields) do
    File.mkdir_p!(sessions_dir())
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

  @doc """
  Load the IMMUTABLE event stream for a session as an ordered list of messages.

  This reads `<id>.updates.jsonl` — the append-only source of truth that
  compaction never prunes — and returns the `msg` payload of each recorded event
  in append order. Corruption-tolerant (a torn line is skipped, not fatal).

  Distinct from `load/1`, which returns the mutable, compaction-pruned transcript
  that `/resume` replays. Use this for full-history replay/rewind. Returns `[]`
  when the session has no event log yet (e.g. sessions saved before this feature).
  """
  @spec load_events(String.t()) :: [map()]
  def load_events(session_id) do
    case Jsonl.read(updates_path(session_id)) do
      {:ok, events, _skipped} -> Enum.map(events, &Map.get(&1, "msg", &1))
      _ -> []
    end
  end

  @doc "Number of events in a session's immutable event log (0 if none)."
  @spec event_count(String.t()) :: non_neg_integer()
  def event_count(session_id) do
    case Jsonl.read(updates_path(session_id)) do
      {:ok, events, _skipped} -> length(events)
      _ -> 0
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp session_path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join(sessions_dir(), "#{safe_id}.json")
  end

  # Path of the immutable append-only event log, sitting next to <id>.json.
  # Named `.updates.jsonl` (not `.json`) so `list/1` and `purge_expired/0` —
  # which filter on `.json` — never treat it as a session record.
  defp updates_path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join(sessions_dir(), "#{safe_id}.updates.jsonl")
  end

  # Append only the messages not already present in the immutable log.
  #
  # `save/3` is called every turn with the full CURRENT (post-compaction)
  # message list — not a delta — so we diff against what the log already holds.
  # Identity is a content hash counted as a MULTISET: the log already has
  # `seen[h]` copies of a message that hashes to `h`; we append the current
  # list's occurrences beyond that. This is compaction-safe by construction:
  #
  #   * a normal turn appends the turn's new tail messages,
  #   * compaction (a shorter list) appends nothing — the log keeps every
  #     pruned message,
  #   * a compaction summary is a brand-new message (new hash) → appended as an
  #     event, and post-compaction regrowth appends the fresh turns,
  #   * legitimately duplicated content (e.g. "ok" twice) is preserved via the
  #     occurrence count rather than being collapsed.
  #
  # Best-effort: never raises, so the already-committed <id>.json save stands.
  defp append_updates(session_id, messages) do
    path = updates_path(session_id)

    existing =
      case Jsonl.read(path) do
        {:ok, events, _skipped} -> events
        _ -> []
      end

    new_events = compute_new_events(messages, existing)
    Jsonl.append(path, new_events)
    :ok
  rescue
    e ->
      Logger.warning("[session_persist] updates log append failed: #{Exception.message(e)}")
      :ok
  end

  defp compute_new_events(messages, existing_events) do
    seen =
      Enum.reduce(existing_events, %{}, fn e, acc ->
        Map.update(acc, Map.get(e, "hash"), 1, &(&1 + 1))
      end)

    max_seq =
      Enum.reduce(existing_events, -1, fn e, m -> max(m, seq_of(e)) end)

    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    {rev_new, _cur, _seq} =
      messages
      |> sanitize_messages()
      |> Enum.reduce({[], %{}, max_seq}, fn msg, {acc, cur, seq} ->
        h = event_hash(msg)
        occurrence = Map.get(cur, h, 0) + 1
        cur = Map.put(cur, h, occurrence)

        if occurrence > Map.get(seen, h, 0) do
          seq = seq + 1
          env = %{"seq" => seq, "ts" => ts, "hash" => h, "msg" => msg}
          {[env | acc], cur, seq}
        else
          {acc, cur, seq}
        end
      end)

    Enum.reverse(rev_new)
  end

  defp seq_of(%{"seq" => n}) when is_integer(n), do: n
  defp seq_of(_), do: -1

  # Stable content hash of a (string-keyed, sanitized) message. Sorted key-value
  # pairs make the JSON deterministic regardless of map iteration order, so the
  # same message hashes identically across saves.
  defp event_hash(msg) when is_map(msg) do
    canonical =
      msg
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> [to_string(k), v] end)
      |> Jason.encode!()

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  rescue
    _ ->
      :crypto.hash(:sha256, inspect(msg)) |> Base.encode16(case: :lower) |> binary_part(0, 16)
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
