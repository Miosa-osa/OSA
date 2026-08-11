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
  alias OptimalSystemAgent.Agent.SessionPersistence.RecordLock
  alias OptimalSystemAgent.ConfigFile

  # Runtime-resolved so a prebuilt release uses the END USER's home, not the CI
  # runner's baked-in path. Resolved on every call via ConfigFile.config_dir/0.
  defp sessions_dir, do: Path.join(ConfigFile.config_dir(), "sessions")

  @max_sessions 50

  @doc """
  Save session state to disk. `working_dir` tags the session to a folder so it
  can be resumed there.

  ## Concurrency

  The whole read-modify-write runs under `RecordLock` (an O_EXCL sidecar lock,
  see that module), so two OSA **OS processes** — every `osa` invocation is its
  own BEAM — cannot interleave their read and their `rename`.

  Serialization alone is not enough, though: a lock only orders the writes, it
  does not stop the *second* writer from installing a transcript derived from a
  state it read before the first writer's turn landed. That was the actual
  defect: `File.rename!` is whole-file last-writer-wins, so a second process
  saving its own view of the session silently discarded the other side's turns.

  So each record also carries a monotonic `rev` and the id of the VM (`writer`)
  that produced it, and this VM remembers the last rev it *observed* for the
  session (set by `load/1` and by every save). Under the lock:

    * on-disk rev == the rev we last observed → our own lineage; the incoming
      list supersedes it wholesale, which is what compaction and rewind (both
      legitimately *shrink* the list) require;
    * on-disk rev has moved on → a **foreign** writer got in. We do not
      overwrite. The transcript becomes the multiset union of the on-disk
      messages and ours (same content-hash identity the immutable event log
      uses), so neither side's turns are dropped, and the conflict is logged
      with both writer ids.

  A session this VM has never read or written has no observed rev; the first
  save then takes the plain-overwrite path, exactly as before. That is the
  honest boundary — we can detect a writer that raced *us*, not one that wrote
  before we ever looked.
  """
  def save(session_id, messages, working_dir \\ nil) when is_list(messages) do
    File.mkdir_p!(sessions_dir())
    path = session_path(session_id)

    result =
      RecordLock.with_lock(path, fn ->
        existing = read_record(path)
        sanitized = sanitize_messages(messages)

        {final_messages, conflict?} = reconcile(session_id, existing, sanitized)

        if conflict? do
          Logger.error(
            "[session_persist] #{session_id}: CONCURRENT WRITER detected " <>
              "(on-disk rev #{rev_of(existing)} by #{inspect(writer_of(existing))}, " <>
              "we last saw rev #{inspect(observed_rev(session_id))} as #{inspect(writer_id())}). " <>
              "Merged both sides — #{length(final_messages)} message(s) kept, none dropped."
          )
        end

        data =
          %{
            "session_id" => session_id,
            "working_dir" => normalize_dir(working_dir),
            "message_count" => length(final_messages),
            "saved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "messages" => final_messages
          }
          # Legacy carry-over: metadata now lives in the `<id>.meta` sidecar
          # (see update_metadata/2), but records written before that split keep
          # title/tags/queued_messages inline. We already hold the old record
          # here, so carrying them costs nothing and keeps old sessions named.
          |> carry_legacy_metadata(existing)

        case write_record(path, session_id, data, existing) do
          :ok ->
            # Two-log persistence: alongside the mutable, compaction-pruned
            # transcript written above (<id>.json), append any newly-seen
            # messages to the IMMUTABLE append-only event log
            # (<id>.updates.jsonl). Compaction shrinks `messages` and rewrites
            # <id>.json, but the immutable log is only ever appended to — it
            # stays the full source of truth for replay/rewind. Best-effort: a
            # failure here never breaks the (already-committed) save.
            append_updates(session_id, final_messages)

            Logger.debug(
              "[session_persist] Saved #{length(final_messages)} messages for #{session_id}"
            )

            :ok

          {:error, reason} = err ->
            Logger.warning("[session_persist] Failed to encode session: #{inspect(reason)}")
            err
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:contended, outcome} -> outcome
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
          {:ok, %{"messages" => messages} = record} when is_list(messages) ->
            # Reading the record establishes this VM's lineage: a later save that
            # finds a DIFFERENT rev on disk knows a foreign writer got in, while
            # a save that still sees this rev is free to shrink the list
            # (compaction, rewind). See save/3.
            observe_rev(session_id, rev_of(record))

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

      {:ok, _events, skipped} ->
        restored =
          session_id
          |> load_events()
          |> Enum.filter(&is_map/1)
          |> Enum.map(fn m -> Map.new(m, fn {k, v} -> {safe_key(k), v} end) end)

        # Recovery is a read that produces a record, so it must establish this
        # VM's write lineage exactly like the normal load path does. It did not,
        # which disabled save/3's merge-on-conflict for precisely the sessions
        # that had just recovered from corruption: with no observed revision,
        # the next save took the plain-overwrite branch and a concurrent
        # writer's turns were dropped. The transcript we recovered from is by
        # definition unreadable, so the observed revision is 0 — any foreign
        # write (rev >= 1) then reads as a conflict and merges.
        observe_rev(session_id, rev_of(read_json(session_path(session_id)) || %{}))

        if skipped > 0 do
          Logger.warning(
            "[session_persist] #{session_id}: #{skipped} torn/unparseable record(s) were " <>
              "skipped while rebuilding from the event log — the recovered transcript may " <>
              "be missing them (raw file preserved as *.corrupt)"
          )
        end

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
              meta = read_meta(path, session_id)

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
    _ = File.rm(RecordLock.lock_path(path))
    _ = File.rm(meta_path(session_id))
    _ = File.rm(spend_path(session_id))
    _ = File.rm(pin_path(session_id))
    forget_rev(session_id)
    File.rm(path)
  end

  @doc """
  Delete saved session files older than the `cleanupPeriodDays` retention window
  (CC-parity; default 30). Called once at startup.

  A value of `0` means **retention disabled** — nothing is age-purged. It does
  NOT mean "delete everything": a config knob whose zero value destroys every
  saved transcript is a footgun, and `Store.SessionTranscript` has always read
  the same `days: 0` as "skip the age purge". The two now agree.

  Negative/invalid values fall back to the 30-day default. Sessions listed in
  the `session_pins` setting, or carrying an `<id>.pin` sidecar, are never
  purged regardless of age. Best-effort: never raises. Returns
  `{:ok, removed_count}`.
  """
  @spec purge_expired() :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired do
    case retention_days() do
      :never ->
        {:ok, 0}

      days ->
        purge_older_than(days)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp purge_older_than(days) do
    cutoff = System.system_time(:second) - days * 86_400

    case File.ls(sessions_dir()) do
      {:ok, files} ->
        removed =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.count(fn file ->
            path = Path.join(sessions_dir(), file)
            session_id = String.trim_trailing(file, ".json")

            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime}} when mtime < cutoff ->
                if pinned?(session_id) do
                  false
                else
                  # Purge the immutable event log + sidecars alongside the
                  # mutable transcript so an expired session leaves no orphans.
                  Jsonl.delete(updates_path(session_id))
                  _ = File.rm(path <> ".corrupt")
                  _ = File.rm(RecordLock.lock_path(path))
                  _ = File.rm(meta_path(session_id))
                  _ = File.rm(spend_path(session_id))
                  forget_rev(session_id)
                  File.rm(path) == :ok
                end

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
  end

  @doc """
  True when a session is protected from `purge_expired/0`.

  Two independent sources, either of which pins: the `session_pins` setting (a
  list of session ids) and an `<id>.pin` sidecar on disk. The sidecar is
  deliberately not `*.json` so neither `list/1` nor `purge_expired/0` — both of
  which enumerate `*.json` — ever mistakes it for a session record.
  """
  @spec pinned?(String.t()) :: boolean()
  def pinned?(session_id) when is_binary(session_id) do
    session_id in configured_pins() or File.exists?(pin_path(session_id))
  rescue
    _ -> false
  end

  def pinned?(_), do: false

  @doc "Protect `session_id` from `purge_expired/0` by writing its `.pin` sidecar."
  @spec pin(String.t()) :: :ok | {:error, term()}
  def pin(session_id) when is_binary(session_id) do
    File.mkdir_p(sessions_dir())
    File.write(pin_path(session_id), "")
  end

  @doc "Remove the `.pin` sidecar, returning `session_id` to normal retention."
  @spec unpin(String.t()) :: :ok | {:error, term()}
  def unpin(session_id) when is_binary(session_id) do
    case File.rm(pin_path(session_id)) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  defp configured_pins do
    case OptimalSystemAgent.Settings.get("session_pins", []) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  rescue
    _ -> []
  end

  # Path of the pin sidecar. Deliberately NOT `*.json` — see `pinned?/1`.
  defp pin_path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join(sessions_dir(), "#{safe_id}.pin")
  end

  # `0` means retention is DISABLED (`:never`), matching `Store.SessionTranscript`.
  defp retention_days do
    case OptimalSystemAgent.Settings.get("cleanupPeriodDays", 30) do
      0 -> :never
      n when is_integer(n) and n > 0 -> n
      _ -> 30
    end
  end

  @doc """
  Merge friendly metadata (e.g. `%{title: ..., tags: [...]}`) into a session.

  ## Why this does not touch `<id>.json`

  This used to be a whole-record read-modify-write: read `<id>.json`, merge the
  fields, write the *entire* record back — messages included. A `/rename`, a
  `/tag`, or (far more often) a `MessageQueue` mutation calling `save_queue/2`
  that overlapped a turn save therefore rewrote the transcript from a snapshot
  taken before the turn landed, and the turn was gone. Not a cross-process
  hazard — that one loses turns *within a single node*, between the loop and
  whatever process ran the metadata update.

  Metadata now lives in its own `<id>.meta` sidecar. A metadata update writes
  only that file, so it shares no bytes with the transcript and there is no
  read-modify-write over `messages` left to lose a race. `<id>.json` is still
  created when absent (empty record) so `/rename` and `/tag` before the first
  message still make the session listable — but an existing transcript is never
  reopened for writing here.

  Returns `:ok` or `{:error, reason}`.
  """
  def update_metadata(session_id, fields) when is_map(fields) do
    File.mkdir_p!(sessions_dir())
    path = session_path(session_id)
    meta = meta_path(session_id)

    result =
      RecordLock.with_lock(meta, fn ->
        existing = read_json(meta) || %{}
        string_fields = Map.new(fields, fn {k, v} -> {to_string(k), v} end)
        write_json(meta, Map.merge(existing, string_fields))
      end)

    outcome =
      case result do
        {:ok, o} -> o
        {:contended, o} -> o
      end

    # Keep a session that only ever had metadata set visible to list/1 and
    # purge_expired/0, both of which enumerate `*.json`. Created ONLY when
    # absent — an existing transcript is never rewritten by a metadata update.
    unless File.exists?(path) do
      RecordLock.with_lock(path, fn ->
        unless File.exists?(path), do: write_json(path, base_record(session_id))
      end)
    end

    outcome
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Read a single session's metadata (title, tags, working_dir)."
  def get_metadata(session_id) do
    read_meta(session_path(session_id), session_id)
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
    # Sidecar first; fall back to the inline field on records written before the
    # metadata split.
    queue =
      case read_json(meta_path(session_id)) do
        %{"queued_messages" => q} when is_list(q) -> q
        _ -> (read_json(session_path(session_id)) || %{})["queued_messages"]
      end

    case queue do
      q when is_list(q) -> for m <- q, is_binary(m), do: m
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Auto-save session state (called from hooks).

  Sends the Loop a `{:persist_session, id}` cast instead of scraping its state
  with `:sys.get_state/1`.

  The old shape was a silent-data-loss defect: `auto_save/1` runs in the
  `:post_response` HOOK process (`Hooks.run_async/2`), so `:sys.get_state(pid)`
  was a cross-process `:sys` call with a 5s default timeout. A loop that is slow
  or busy — exactly what a long session produces — made it exit with
  `{:timeout, _}`, and the whole save (transcript AND spend) was dropped with no
  log and no retry while the turn reported success.

  A cast is QUEUED by a busy loop rather than dropped, and the loop supplies its
  own state (`handle_cast({:persist_session, _})` → `save_from_state/2`) instead
  of having it scraped from outside. If the cast itself cannot be delivered we
  LOG at warning with the session id — never a blanket `rescue _ -> :ok`.
  """
  def auto_save(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] ->
        try do
          GenServer.cast(pid, {:persist_session, session_id})
          :ok
        rescue
          e ->
            Logger.warning(
              "[session_persist] #{session_id}: could not enqueue save: #{Exception.message(e)}"
            )

            {:error, Exception.message(e)}
        catch
          :exit, reason ->
            Logger.warning(
              "[session_persist] #{session_id}: could not enqueue save: #{inspect(reason)}"
            )

            {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @doc """
  Persist a live Loop's state. Called by the Loop itself from
  `handle_cast({:persist_session, id}, state)` so the save is serialized by the
  loop's own mailbox and always sees a consistent state.

  A failure here LOGS at warning with the session id — a persistence path must
  never fail silently.
  """
  @spec save_from_state(String.t(), map()) :: :ok | {:error, term()}
  def save_from_state(session_id, state) when is_binary(session_id) and is_map(state) do
    # `|| []` and not a Map.get/3 default. This gates what gets WRITTEN: a
    # present-but-nil `:messages` skips the default and would persist an empty
    # message set over a real session. The `|| []` at least keeps the nil case
    # on the same code path as the absent case instead of writing nil through.
    with :ok <- save(session_id, Map.get(state, :messages) || [], Map.get(state, :working_dir)),
         # Persist the running spend at the turn boundary too (audit gap C2).
         # The crash-recovery checkpoint is cleared on a clean turn end, so this
         # is what carries accumulated spend into a resume AFTER a completed turn.
         :ok <- save_spend(session_id, spend_from_state(state)) do
      :ok
    else
      {:error, reason} = err ->
        Logger.warning("[session_persist] #{session_id}: save failed: #{inspect(reason)}")
        err

      other ->
        other
    end
  rescue
    e ->
      Logger.warning("[session_persist] #{session_id}: save crashed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  def save_from_state(session_id, _state) do
    Logger.warning("[session_persist] #{inspect(session_id)}: save skipped — invalid state")
    {:error, :invalid_state}
  end

  # ── Durable spend sidecar (audit gap C2) ─────────────────────────────────
  #
  # A tiny `<id>.spend.json` next to the session transcript that holds ONLY the
  # running budget totals. It is written every tool cycle (via Checkpoint) and
  # every turn boundary (via auto_save), and — unlike the crash-recovery
  # checkpoint — is NOT cleared when a turn ends cleanly. That makes accumulated
  # spend survive BOTH a mid-turn crash and a resume after a completed turn, so a
  # `max_budget_usd` cap keeps holding across the whole run.

  @doc "Persist the running per-session spend totals (atomic write). Best-effort."
  @spec save_spend(String.t(), map()) :: :ok | {:error, term()}
  def save_spend(session_id, spend) when is_binary(session_id) and is_map(spend) do
    File.mkdir_p!(sessions_dir())
    write_json(spend_path(session_id), stringify_spend(spend))
  rescue
    e -> {:error, Exception.message(e)}
  end

  def save_spend(_, _), do: {:error, :invalid_args}

  @doc """
  Load the durable per-session spend totals. Returns a map with atom keys and
  zero defaults when no sidecar exists yet (never raises).
  """
  @spec load_spend(String.t()) :: %{
          cost_usd: number(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          started_at: String.t() | nil,
          complete: boolean()
        }
  def load_spend(session_id) when is_binary(session_id) do
    with {:ok, json} <- File.read(spend_path(session_id)),
         {:ok, data} when is_map(data) <- Jason.decode(json) do
      %{
        cost_usd: spend_num(data["cost_usd"], 0.0),
        input_tokens: spend_num(data["input_tokens"], 0),
        output_tokens: spend_num(data["output_tokens"], 0),
        cache_creation_tokens: spend_num(data["cache_creation_tokens"], 0),
        cache_read_tokens: spend_num(data["cache_read_tokens"], 0),
        started_at: data["started_at"],
        # This is a real reading of a real sidecar.
        complete: true
      }
    else
      _ -> zero_spend()
    end
  rescue
    _ -> zero_spend()
  end

  def load_spend(_), do: zero_spend()

  # "We have no bill for this session" — NOT "this session was free".
  #
  # The numbers are zeros because every caller does arithmetic and formatting on
  # them, but `complete: false` says the zeros are a placeholder rather than a
  # measurement. Spend ENFORCEMENT must branch on `:complete` and refuse to
  # treat an absent bill as $0.00; DISPLAY may keep showing `—`.
  defp zero_spend do
    %{
      cost_usd: 0.0,
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      started_at: nil,
      complete: false
    }
  end

  defp spend_from_state(state) do
    %{
      cost_usd: Map.get(state, :session_cost_usd, 0.0),
      input_tokens: Map.get(state, :session_input_tokens, 0),
      output_tokens: Map.get(state, :session_output_tokens, 0),
      cache_creation_tokens: Map.get(state, :session_cache_creation_tokens, 0),
      cache_read_tokens: Map.get(state, :session_cache_read_tokens, 0),
      started_at: started_at_string(Map.get(state, :started_at))
    }
  end

  defp started_at_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp started_at_string(s) when is_binary(s), do: s
  defp started_at_string(_), do: nil

  defp stringify_spend(spend), do: Map.new(spend, fn {k, v} -> {to_string(k), v} end)

  defp spend_num(v, _default) when is_number(v), do: v
  defp spend_num(_, default), do: default

  defp spend_path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join(sessions_dir(), "#{safe_id}.spend.json")
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
      {:ok, events, skipped} ->
        if skipped > 0 do
          Logger.warning(
            "[session_persist] #{session_id}: #{skipped} torn/unparseable record(s) skipped " <>
              "while reading the immutable event log — replay is incomplete by that many " <>
              "records (raw file preserved as *.corrupt)"
          )
        end

        Enum.map(events, &Map.get(&1, "msg", &1))

      _ ->
        []
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

  # Path of the metadata sidecar (title/tags/queued_messages). Deliberately NOT
  # `*.json`: `list/1` and `purge_expired/0` enumerate `*.json` and would
  # otherwise mistake it for a second session record.
  defp meta_path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join(sessions_dir(), "#{safe_id}.meta")
  end

  # ── Concurrent-writer detection (defect 3) ───────────────────────────
  #
  # `rev` is a per-record monotonic counter and `writer` names the VM that
  # produced the record. Together with the rev this VM last OBSERVED they let
  # save/3 tell "I am overwriting my own lineage" (fine — that is compaction and
  # rewind) apart from "someone else wrote while I was thinking" (not fine —
  # a plain rename would drop their turns).

  defp rev_of(%{"rev" => n}) when is_integer(n), do: n
  defp rev_of(_), do: 0

  defp writer_of(%{"writer" => w}) when is_binary(w), do: w
  defp writer_of(_), do: nil

  # Per-VM identity, minted once. persistent_term is the right home: written
  # once, read on every save, and visible to every process in this BEAM.
  defp writer_id do
    key = {__MODULE__, :writer_id}

    case :persistent_term.get(key, nil) do
      nil ->
        id =
          "#{node()}/#{System.pid()}/#{System.unique_integer([:positive])}"

        :persistent_term.put(key, id)
        id

      id ->
        id
    end
  end

  # The rev this VM last saw for a session (nil = never read or written here).
  # Updated by load/1 and by every successful save; puts happen at turn cadence,
  # not in a hot loop, so persistent_term's global-scan cost is irrelevant.
  defp observed_rev(session_id), do: :persistent_term.get({__MODULE__, :rev, session_id}, nil)

  defp observe_rev(session_id, rev) when is_integer(rev) do
    :persistent_term.put({__MODULE__, :rev, session_id}, rev)
    :ok
  end

  defp observe_rev(_, _), do: :ok

  defp forget_rev(session_id) do
    _ = :persistent_term.erase({__MODULE__, :rev, session_id})
    :ok
  end

  # Decide what the transcript should contain. Returns {messages, conflict?}.
  defp reconcile(_session_id, nil, incoming), do: {incoming, false}

  defp reconcile(session_id, existing, incoming) do
    seen = observed_rev(session_id)
    on_disk = rev_of(existing)

    cond do
      # Never looked at this session in this VM — we have no basis to call
      # anything a conflict, so behave as before (plain overwrite).
      is_nil(seen) ->
        {incoming, false}

      seen == on_disk ->
        {incoming, false}

      true ->
        # `|| []`: `existing` is decoded from a file on disk, where
        # `"messages": null` is a real shape. The Map.get/3 default does not
        # fire for a present null and Enum.filter/2 on nil raises — inside a
        # merge whose whole job is to not lose the other writer's messages.
        prior = Enum.filter(Map.get(existing, "messages") || [], &is_map/1)
        {union_messages(prior, incoming), true}
    end
  end

  # Multiset union by content hash, prior side first: everything the foreign
  # writer committed is kept, and our messages are appended in order for each
  # occurrence beyond what the prior list already accounts for. Uses the same
  # identity function as the immutable event log, so "the same turn saved by
  # both sides" collapses to one entry rather than duplicating.
  defp union_messages(prior, incoming) do
    seen =
      Enum.reduce(prior, %{}, fn m, acc -> Map.update(acc, event_hash(m), 1, &(&1 + 1)) end)

    {extra, _} =
      Enum.flat_map_reduce(incoming, %{}, fn msg, cur ->
        h = event_hash(msg)
        occurrence = Map.get(cur, h, 0) + 1
        cur = Map.put(cur, h, occurrence)

        if occurrence > Map.get(seen, h, 0), do: {[msg], cur}, else: {[], cur}
      end)

    prior ++ extra
  end

  defp read_record(path) do
    case read_json(path) do
      %{} = data -> data
      _ -> nil
    end
  end

  defp carry_legacy_metadata(data, nil), do: data

  defp carry_legacy_metadata(data, existing) do
    Enum.reduce(["title", "tags", "queued_messages"], data, fn key, acc ->
      case Map.get(existing, key) do
        nil -> acc
        val -> Map.put(acc, key, val)
      end
    end)
  end

  # Stamp the record with the next rev + this VM's writer id, install it
  # atomically, and remember the rev we just wrote.
  defp write_record(path, session_id, data, existing) do
    rev = rev_of(existing) + 1

    stamped =
      data
      |> Map.put("rev", rev)
      |> Map.put("writer", writer_id())

    case write_json(path, stamped) do
      :ok ->
        observe_rev(session_id, rev)
        :ok

      other ->
        other
    end
  end

  # Path of the immutable append-only event log, sitting next to <id>.json.
  # Named `.updates.jsonl` (not `.json`) so `list/1` and `purge_expired/0` —
  # which filter on `.json` — never treat it as a session record.
  defp updates_path(session_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
    Path.join(sessions_dir(), "#{safe_id}.updates.jsonl")
  end

  # Path of the projection cursor sidecar (see `append_updates/2`). Lives next to
  # the log as `<id>.updates.jsonl.cursor` so `Jsonl.delete/1` — which sweeps the
  # log's sidecars — retires it with the session, and so neither `list/1` nor
  # `purge_expired/0` (both filter on a `.json` suffix) ever sees it.
  defp cursor_path(session_id), do: updates_path(session_id) <> ".cursor"

  # Append only the messages not already present in the immutable log.
  #
  # `save/3` is called every turn with the full CURRENT (post-compaction)
  # message list — not a delta — so we must work out what the log does not have
  # yet. There are two paths:
  #
  # ## Fast path — the projection cursor (O(new messages))
  #
  # The append-only log stays the source of truth; a tiny `*.cursor` sidecar
  # makes it *incrementally projectable* (Codex's `thread_history_projection_state`
  # idea). The cursor records, for the last message list we projected:
  #
  #   * `log_size`   — byte size of the log right after that append,
  #   * `next_seq`   — the seq to assign the next event,
  #   * `msg_count`  — how many of the list's messages are already in the log,
  #   * `head_hash` / `tail_hash` — the hashes of message 0 and message
  #     `msg_count - 1`.
  #
  # When the log's on-disk size still matches `log_size` (nobody else appended,
  # and we did not crash between the append and the cursor write) and the current
  # list still has the same head and the same message at index `msg_count - 1`,
  # the list is a pure APPEND onto what we already projected. We then hash and
  # write only `Enum.drop(messages, msg_count)`. Per-turn cost stops scaling with
  # history length — which is the whole point: the previous implementation read
  # the entire log back and SHA-256'd every message in it on every single turn,
  # i.e. O(N) work per turn and O(N²) over a session (~17 ms/turn at 1600
  # messages, and climbing).
  #
  # ## Slow path — full multiset diff (correctness backstop)
  #
  # Any cursor miss (no cursor, stale size after a crash or a concurrent writer,
  # head/tail divergence — which is exactly what compaction and rewind look like)
  # falls back to the original full-log diff, then rewrites the cursor. Identity
  # is a content hash counted as a MULTISET: the log already has `seen[h]` copies
  # of a message that hashes to `h`; we append the current list's occurrences
  # beyond that. That is compaction-safe by construction:
  #
  #   * a normal turn appends the turn's new tail messages,
  #   * compaction (a shorter list) appends nothing — the log keeps every
  #     pruned message,
  #   * a compaction summary is a brand-new message (new hash) → appended as an
  #     event, and post-compaction regrowth appends the fresh turns,
  #   * legitimately duplicated content (e.g. "ok" twice) is preserved via the
  #     occurrence count rather than being collapsed.
  #
  # Because every miss self-heals into the slow path, the cursor can be deleted,
  # truncated or corrupted at any time without losing an event: it is a cache of
  # a derivable fact, never a second source of truth. Crash-resumability comes
  # from `log_size` — a crash between append and cursor write leaves a short size
  # and the next turn re-derives from the log itself.
  #
  # Best-effort: never raises, so the already-committed <id>.json save stands.
  defp append_updates(session_id, messages) do
    path = updates_path(session_id)

    case fast_forward(path, session_id, messages) do
      {:ok, new_events, cursor} ->
        Jsonl.append(path, new_events)
        write_cursor(session_id, Map.put(cursor, "log_size", file_size(path)))

      :miss ->
        slow_path_append(session_id, path, messages)
    end

    :ok
  rescue
    e ->
      Logger.warning("[session_persist] updates log append failed: #{Exception.message(e)}")
      :ok
  end

  # Full multiset diff against the log.
  #
  # The read of the log MUST NOT fail open. Coercing a read error to `[]` (which
  # is what this used to do) makes `seen` empty, so the delta becomes "every
  # message in the session" and the whole transcript is duplicated into the
  # immutable log — and because identity here is a content-hash MULTISET, a
  # wholesale duplicate is indistinguishable from a session that legitimately
  # repeated its messages. It cannot be detected or undone afterwards.
  #
  # A transient EACCES / ENOMEM / lock contention is exactly the condition that
  # triggers it. So: a read error ABORTS the append. Skipping one append is
  # recoverable — the next save re-derives the same delta from the log — while a
  # corrupted recovery log is not.
  defp slow_path_append(session_id, path, messages) do
    case Jsonl.read(path) do
      {:ok, existing, skipped} ->
        if skipped > 0 do
          # `Jsonl.read/1` already quarantined the raw file. Say out loud what
          # happens next: the torn records are absent from `seen`, so the diff
          # below re-appends them. That is a repair, not a duplication — but a
          # silent repair is how a log quietly grows junk lines, so it is logged
          # with the session id.
          Logger.warning(
            "[session_persist] #{session_id}: #{skipped} torn/unparseable record(s) in the " <>
              "event log were skipped; their content will be RE-APPENDED by this save " <>
              "(the raw file was preserved as *.corrupt)"
          )
        end

        new_events = compute_new_events(messages, existing)
        Jsonl.append(path, new_events)

        next_seq =
          (existing ++ new_events)
          |> Enum.reduce(-1, fn e, m -> max(m, seq_of(e)) end)
          |> Kernel.+(1)

        rebuild_cursor(session_id, path, next_seq, messages)

      {:error, reason} ->
        Logger.error(
          "[session_persist] #{session_id}: could not read the immutable event log " <>
            "(#{inspect(reason)}) — SKIPPING this append rather than treating the log as " <>
            "empty, which would duplicate the entire transcript into it. The next save " <>
            "re-derives the same delta."
        )

        :ok
    end
  end

  # Try to satisfy the append from the cursor alone. Returns the events to write
  # plus the updated cursor (its `log_size` is filled in after the append), or
  # `:miss` to force the full-diff path.
  defp fast_forward(path, session_id, messages) do
    with %{
           "v" => 2,
           "log_size" => log_size,
           "next_seq" => next_seq,
           "msg_count" => n,
           "span_hash" => span_hash
         }
         when is_integer(log_size) and is_integer(next_seq) and is_integer(n) and n >= 0 <-
           read_cursor(session_id),
         true <- file_size(path) == log_size,
         total = length(messages),
         true <- total >= n,
         true <- span_matches?(messages, n, span_hash) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()

      {events, last_seq} =
        messages
        |> Enum.drop(n)
        |> sanitize_messages()
        |> Enum.map_reduce(next_seq, fn msg, seq ->
          {%{"seq" => seq, "ts" => ts, "hash" => event_hash(msg), "msg" => msg}, seq + 1}
        end)

      cursor = %{
        "v" => 2,
        "log_size" => log_size,
        "next_seq" => last_seq,
        "msg_count" => total,
        "span_hash" => span_hash(messages, total)
      }

      {:ok, events, cursor}
    else
      _ -> :miss
    end
  end

  # Is the current list still a pure APPEND onto the span we already projected?
  #
  # This used to compare only the endpoint hashes — message 0 and message
  # `n - 1`. That is blind to an IN-PLACE rewrite of any message strictly
  # between them: both endpoints still match, the fast path declares "pure
  # append", writes only `Enum.drop(messages, n)`, and the mutation never
  # reaches the immutable log. `Compactor.apply_step(:micro_compact, ...)` has
  # exactly that shape — it rewrites older `role: "tool"` contents in place and
  # leaves the head and tail alone — so `<id>.json` recorded the prune and
  # `<id>.updates.jsonl` did not. A later events-fallback recovery then restored
  # pre-prune content the live session had deliberately dropped: the two logs
  # diverged, silently.
  #
  # The fingerprint is now over the WHOLE projected prefix, so any interior edit
  # is a miss and routes to the full multiset diff (which is correct by
  # construction). Cost is one pass over the prefix per save — cheap next to the
  # full-log read + per-message SHA-256 + JSON encode that a miss costs, and the
  # only price at which "the log cannot silently miss an edit" is available.
  defp span_matches?(_messages, 0, _span_hash), do: true

  defp span_matches?(messages, n, span_hash), do: span_hash(messages, n) == span_hash

  # Content fingerprint of the first `n` messages. `messages` reaching here is
  # already sanitized (string-keyed plain maps), and Erlang encodes small maps
  # with their keys in canonical order, so `term_to_binary/1` is deterministic
  # across saves and across VMs.
  defp span_hash(_messages, 0), do: nil

  defp span_hash(messages, n) do
    messages
    |> Enum.take(n)
    |> sanitize_messages()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp read_cursor(session_id) do
    with {:ok, json} <- File.read(cursor_path(session_id)),
         {:ok, data} when is_map(data) <- Jason.decode(json) do
      data
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp write_cursor(session_id, cursor) do
    write_json(cursor_path(session_id), cursor)
    :ok
  rescue
    _ -> :ok
  end

  # After a slow-path append, re-derive the cursor from the message list we just
  # projected. `next_seq` is `max(seq) + 1` over the whole log (not the event
  # count) so legacy logs written before seqs were dense stay monotonic.
  defp rebuild_cursor(session_id, path, next_seq, messages) do
    total = length(messages)

    write_cursor(session_id, %{
      "v" => 2,
      "log_size" => file_size(path),
      "next_seq" => next_seq,
      "msg_count" => total,
      "span_hash" => span_hash(messages, total)
    })
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

  # Cheaply read display metadata (working_dir, title, tags).
  #
  # `working_dir` is a property of the transcript (set by save/3); `title`/`tags`
  # live in the `<id>.meta` sidecar. Records written before the sidecar split
  # carry title/tags inline, so the record is the fallback — an old session keeps
  # its name without a migration step.
  defp read_meta(path, session_id) do
    record = read_json(path) || %{}
    meta = read_json(meta_path(session_id)) || %{}

    %{
      working_dir: record["working_dir"],
      title: meta["title"] || record["title"],
      tags: normalize_tags(meta["tags"] || record["tags"])
    }
  end

  defp read_json(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} when is_map(data) <- Jason.decode(json) do
      data
    else
      _ -> nil
    end
  rescue
    _ -> nil
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
