defmodule OptimalSystemAgent.Tools.FileState do
  @moduledoc """
  Per-session read-state tracker — OSA's equivalent of Claude Code's
  `readFileState` map (`FileEditTool.ts`) and hermes' `tools/file_state.py`.

  ## Why this exists (P0-1: read-before-edit + stale-write detection)

  `file_write/prompt.ex` promises the model *"This tool will fail if you did
  not read the file first"* — but historically **no handler enforced it**.
  Without a read-state ledger, a long agent run can:

    * `file_write` (overwrite) a file it never read → clobbering content it
      never saw, and
    * edit a file that changed **since** it last read it (a linter reformatted
      it, the user edited it, a sub-agent touched it) → landing an edit against
      a stale mental model or silently reverting those changes.

  This module records, per session, the `{mtime, size}` observed on every
  successful `file_read`, and lets the edit/write handlers reject a write when
  the target was never read this session (a) or has changed on disk since the
  recorded read (b). After a successful write, the entry is refreshed so
  back-to-back edits in the same turn don't false-trip.

  ## Storage

  A single public, named ETS table (`#{inspect(:osa_tool_file_state)}`) keyed by
  `{session_id, canonical_path}` → `%{mtime, size, read_at}`. The table is owned
  by a lazily-started, unsupervised `GenServer` (same self-owning-ETS pattern the
  hook engine uses). It is deliberately **not** in the supervision tree: this
  module owns exactly the files listed in its change-set and must not wire itself
  into the application supervisor. If the owner ever dies, the table is recreated
  on next use and the worst case is the model re-reading a file — never a
  corrupt write.

  ## Enforcement scope

  Enforcement is a *session-level* guarantee. The `nil` session (no session
  context) and the `"test"` sentinel used by `UseContext.empty/0` — the context
  the flat backwards-compat shims and unit tests run under — are **exempt**, so
  context-free direct tool calls keep working. Real `ReactLoop` sessions always
  carry a concrete session id and are enforced.

  ## Second role: "does the model already hold this content?" (redundant-read
  suppression)

  The same ledger answers a *different* question the agent loop needs, and it is
  the reason this module grew a content hash. Measured on the
  `schemelike-metacircular-eval` head-to-head run: **59 `file_read` calls against
  one path with byte-identical arguments**, each pulling the whole of a growing
  file back into context, in a `read -> edit -> read -> edit` cycle. Input cost
  is quadratic in turns once the transcript dominates the static prefix, so
  re-injecting a growing file is the single largest cost driver measured.

  `read_status/3` distinguishes three cases, and the distinction is the whole
  design:

    * `:unchanged` — this session already read *this exact range* of this path,
      and the bytes on disk are identical (mtime **and** size **and** content
      hash). The content is verbatim in context. `file_read` answers with a
      short marker instead of the bytes.
    * `:changed` — the path was read but the bytes differ now. This is the
      `read -> edit -> verify` pattern *working correctly* and it must never be
      suppressed; the real content is returned.
    * `:never_read` / `:unknown` — no basis to suppress. Real content.

  Three deliberate conservatism rules, because returning real content is always
  safe and returning "unchanged" wrongly is not:

    1. **Ranges are tracked individually.** An entry carries the set of
       `offset/limit` windows actually read, keyed verbatim. Only a
       byte-identical repeat of a window already delivered is answered with the
       notice. Windows that *overlap* are handled on a different axis — see
       `held_lines/2` and range subtraction below — because a partly-new window
       has a partly-new answer, and a yes/no verdict cannot give it.
    2. **Any write clears the range set.** `record_write/2` refreshes
       `{mtime, size, hash}` (so staleness enforcement keeps working) but drops
       every recorded range, because after an edit the model holds a *delta*,
       not the file. The verify-read after an edit therefore always returns
       real content.
    3. **Compaction invalidates everything.** Each entry stamps the session's
       compaction epoch. If a compaction has run since the read, the content
       may have been summarised out of the transcript, so the entry no longer
       proves the model holds it. `bump_epoch/1` is called from
       `Agent.CompactionEvents.completed/2`.

  ## Third role: range subtraction (`held_lines/2`)

  The exact-window verdict above turned out to address the wrong 0.8%. Measured
  over 118 transcripts (1,142 `file_read` calls, 2.63 MB delivered): 708 calls
  re-read an already-read path, but only 19 of them — 20 KB, 0.8% of the
  payload — asked for the byte-identical window a same/different verdict can
  catch. Overlapping windows and whole-file re-reads together are 31.5%.

  Those calls are *partly* new, so the operation they need is not a verdict but
  a subtraction: the session holds lines 40–80, the model asks for 1–120, and
  the honest answer is 1–39 plus 81–120 with the omission named. `held_lines/2`
  is the state half of that; `FileRead.Spans` is the arithmetic. Both ride on
  the same entry and the same validity guard as everything above — one ledger of
  "what has this session been shown", not two.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Spans

  @table :osa_tool_file_state

  # Sessions exempt from read-before-edit enforcement:
  #   * nil    — no session context (direct/library call, nothing to track)
  #   * "test" — the sentinel session from `UseContext.empty/0` used by the
  #              flat compat shims and unit-test callers that predate tracking.
  @exempt_sessions [nil, "test"]

  # ── GenServer (ETS owner) ─────────────────────────────────────────────

  @doc false
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    ensure_ets()
    {:ok, %{}}
  end

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Record a successful read of `path` for `session_id`.

  `opts` accepts:

    * `:range` — the `offset`/`limit` window actually delivered to the model, as
      returned by `range_key/2`. Defaults to `:whole`. The range is *added* to
      the entry's range map when the bytes are unchanged, and *replaces* it when
      they are not, so the map only ever describes windows of the current
      content.
    * `:bytes` — how many bytes that window actually delivered. Recorded so a
      caller can tell whether replacing the window with a short notice would
      save anything; a windowed read of a large file can deliver very few bytes.
    * `:lines` — the LINE SPANS actually delivered, as `[{first, last}]`. This
      is the axis range subtraction works on (see `held_lines/2`); it is
      recorded separately from `:range` because `:range` is a verbatim key for
      the arguments and spans are an interval algebra over the file. Omitted for
      byte-axis reads, images and errors, all of which record no spans at all.

  Idempotent and best-effort — a stat failure (file vanished between read and
  record) is silently ignored rather than raised.
  """
  @spec record_read(term(), String.t(), keyword()) :: :ok
  def record_read(session_id, path, opts \\ []) do
    ensure_table()
    cpath = fs_path(path)
    key = {skey(session_id), key_path(cpath)}
    range = Keyword.get(opts, :range, :whole)
    delivered = Keyword.get(opts, :bytes, 0)
    lines = Keyword.get(opts, :lines, [])

    case stat(cpath) do
      {:ok, mtime, size} ->
        hash = content_hash(cpath, size)
        epoch = epoch(session_id)

        # Carry forward previously-read ranges only when the bytes are provably
        # the same content the model already holds. Any difference in
        # hash/mtime/size — or an intervening compaction — starts a fresh set.
        # The line spans ride on exactly the same guard, because they make
        # exactly the same claim: "the model is holding these bytes."
        {prior_ranges, prior_lines} =
          case safe_lookup(key) do
            [{^key, %{hash: ^hash, mtime: ^mtime, size: ^size, epoch: ^epoch} = prior}] ->
              {take_map(prior, :ranges), take_list(prior, :lines)}

            _ ->
              {%{}, []}
          end

        entry = %{
          mtime: mtime,
          size: size,
          hash: hash,
          epoch: epoch,
          ranges: Map.put(prior_ranges, range, delivered),
          lines: Spans.union(prior_lines, lines),
          read_at: System.system_time(:second)
        }

        safe_insert(key, entry)

      :error ->
        :ok
    end
  end

  defp take_map(entry, key) do
    case Map.get(entry, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp take_list(entry, key) do
    case Map.get(entry, key) do
      l when is_list(l) -> l
      _ -> []
    end
  end

  @doc """
  Refresh the read-state entry after a successful write, so a subsequent edit
  to the same file in the same turn is not flagged stale.

  Deliberately **not** an alias for `record_read/3`: the write refreshes
  `{mtime, size, hash}` so staleness enforcement keeps passing, but drops every
  recorded range. After an edit the model holds the delta it authored, not the
  resulting file — so the next `file_read` of that path must return real
  content. This is the `read -> edit -> verify` exemption, and it lives here
  rather than in the detector so every caller gets it for free.
  """
  @spec record_write(term(), String.t()) :: :ok
  def record_write(session_id, path) do
    ensure_table()
    cpath = fs_path(path)
    key = {skey(session_id), key_path(cpath)}

    case stat(cpath) do
      {:ok, mtime, size} ->
        entry = %{
          mtime: mtime,
          size: size,
          hash: content_hash(cpath, size),
          epoch: epoch(session_id),
          ranges: %{},
          lines: [],
          read_at: System.system_time(:second)
        }

        safe_insert(key, entry)

      :error ->
        :ok
    end
  end

  @doc """
  Which LINE SPANS of `path` this session is currently holding, verbatim and
  still valid.

  Returns `[]` — never a stale answer — when there is no entry, when the file's
  `{mtime, size, content hash}` disagrees with the recorded read, when a
  compaction has run since, or when the session is exempt from enforcement.
  Every one of those is a reason the model may no longer hold what the ledger
  says it holds, and the cost asymmetry is the same one that governs
  `read_status/3`: an unnecessary re-read costs tokens, a wrong "you have this"
  costs the model its working context.

  This is the state `FileRead` subtracts a requested window against. It is
  deliberately the SAME entry, guarded by the SAME hash/mtime/size/epoch checks,
  as byte-identical suppression — there is one ledger of "what has this session
  been shown", not two.
  """
  @spec held_lines(term(), String.t()) :: [Spans.span()]
  def held_lines(session_id, path) do
    if enforce?(session_id) do
      ensure_table()
      cpath = fs_path(path)
      key = {skey(session_id), key_path(cpath)}

      case safe_lookup(key) do
        [{^key, %{mtime: rmtime, size: rsize, hash: rhash, epoch: repoch} = entry}] ->
          with true <- repoch == epoch(session_id),
               {:ok, ^rmtime, ^rsize} <- stat(cpath),
               ^rhash when not is_nil(rhash) <- content_hash(cpath, rsize) do
            entry |> take_list(:lines) |> Spans.normalize()
          else
            _ -> []
          end

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Canonical key for an `offset`/`limit` window, as passed to `file_read`.

  `nil`/absent offset *and* limit means the whole file. Anything else is keyed
  by the literal pair, so `{offset: 1, limit: 50}` and `{offset: nil, limit: 50}`
  are distinct windows even if they happen to deliver the same lines — a
  deliberate over-approximation, since the cost of being wrong in this direction
  is one redundant read and the cost of being wrong in the other is lost content.
  """
  @spec range_key(term(), term()) :: :whole | {term(), term()}
  def range_key(nil, nil), do: :whole
  def range_key(offset, limit), do: {offset, limit}

  @doc """
  Has `session_id` already been handed this exact `range` of `path`, with the
  bytes unchanged since?

  Returns:
    * `{:unchanged, %{bytes: n}}` — safe to answer with a marker instead of the
      bytes; `n` is how many bytes the earlier read of this window delivered, so
      the caller can decline when a notice would not be smaller.
    * `:changed` — read before, but the content differs now (or a different
      window is being asked for, or a write intervened). Return real content.
    * `:never_read` — no entry for this `{session, path}`.
    * `:unknown` — cannot stat / cannot hash / session exempt. Return real
      content.

  Every non-`{:unchanged, _}` answer means "return the real content", so a
  caller may treat this as a two-way decision and still be correct.
  """
  @spec read_status(term(), String.t(), :whole | {term(), term()}) ::
          {:unchanged, map()} | :changed | :never_read | :unknown
  def read_status(session_id, path, range \\ :whole) do
    if enforce?(session_id) do
      ensure_table()
      cpath = fs_path(path)
      key = {skey(session_id), key_path(cpath)}

      case safe_lookup(key) do
        [{^key, %{mtime: rmtime, size: rsize, hash: rhash, epoch: repoch, ranges: ranges}}]
        when is_map(ranges) ->
          cond do
            # A compaction ran since the read: the content may have been
            # summarised out of the transcript, so the entry no longer proves
            # the model still holds it. Never suppress across an epoch bump.
            repoch != epoch(session_id) ->
              :changed

            not Map.has_key?(ranges, range) ->
              :changed

            true ->
              case stat(cpath) do
                {:ok, ^rmtime, ^rsize} ->
                  # mtime+size agree; the hash is the tiebreak for an in-place
                  # same-length edit inside one mtime granule.
                  case content_hash(cpath, rsize) do
                    ^rhash when not is_nil(rhash) ->
                      {:unchanged, %{bytes: Map.get(ranges, range, 0)}}

                    nil ->
                      :unknown

                    _other ->
                      :changed
                  end

                {:ok, _mtime, _size} ->
                  :changed

                :error ->
                  :unknown
              end
          end

        _ ->
          :never_read
      end
    else
      :unknown
    end
  end

  @doc """
  The session's compaction epoch. Bumped by `bump_epoch/1` on every completed
  compaction; stamped into every entry so a read recorded before a compaction
  can never suppress a read after it.
  """
  @spec epoch(term()) :: non_neg_integer()
  def epoch(session_id) do
    ensure_table()

    case safe_lookup(epoch_key(session_id)) do
      [{_key, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc """
  Record that a compaction completed for `session_id`, invalidating every
  redundant-read suppression recorded before it.

  Best-effort and never raises: losing an epoch bump costs at worst one
  suppressed read the model may have to ask for again, so this must not be able
  to fail a compaction.
  """
  @spec bump_epoch(term()) :: :ok
  def bump_epoch(session_id) do
    ensure_table()
    key = epoch_key(session_id)

    try do
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
      :ok
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Verify `path` may be edited/overwritten by `session_id`.

  Returns:
    * `:ok` — the path was read this session and has not changed since, OR the
      session is exempt from enforcement.
    * `{:error, message}` — the path was never read this session, or it changed
      on disk since the recorded read. `message` is a model-directed instruction
      to (re-)read the file first.

  New-file writes (creating a file that does not yet exist) must **not** call
  this — creating a fresh file is always allowed.
  """
  @spec check_read(term(), String.t()) :: :ok | {:error, String.t()}
  def check_read(session_id, path) do
    if enforce?(session_id) do
      ensure_table()
      cpath = fs_path(path)
      key = {skey(session_id), key_path(cpath)}

      case safe_lookup(key) do
        [{^key, %{mtime: rmtime, size: rsize}}] ->
          case stat(cpath) do
            {:ok, ^rmtime, ^rsize} ->
              :ok

            {:ok, _mtime, _size} ->
              {:error, stale_message(path)}

            :error ->
              # File disappeared since the read; let the write path surface the
              # concrete filesystem error rather than a stale-write message.
              :ok
          end

        _ ->
          {:error, not_read_message(path)}
      end
    else
      :ok
    end
  end

  @doc "True when `session_id` is subject to read-before-edit enforcement."
  @spec enforce?(term()) :: boolean()
  def enforce?(session_id), do: session_id not in @exempt_sessions

  @doc """
  True when `path` has a recorded read for `session_id`. Convenience for
  callers/tests; enforcement should use `check_read/2`.
  """
  @spec read?(term(), String.t()) :: boolean()
  def read?(session_id, path) do
    ensure_table()
    key = {skey(session_id), key_path(fs_path(path))}
    match?([{^key, _}], safe_lookup(key))
  end

  @doc "Drop every tracked entry. Test/maintenance helper."
  @spec reset() :: :ok
  def reset do
    ensure_table()

    try do
      :ets.delete_all_objects(@table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ── Messages (model-directed) ─────────────────────────────────────────

  defp not_read_message(path) do
    "You must read #{path} with file_read before editing or overwriting it. " <>
      "Read the file first so you are editing against its current contents, then retry."
  end

  defp stale_message(path) do
    "#{path} has changed on disk since you last read it — a linter, the user, or " <>
      "another tool/sub-agent may have modified it. Your view of the file is stale. " <>
      "Re-read it with file_read to see the current contents, then retry your edit."
  end

  # ── Internals ─────────────────────────────────────────────────────────

  # Normalise a session id into a stable, hashable key component.
  defp skey(session_id) when is_binary(session_id), do: session_id
  defp skey(session_id), do: session_id

  # The real filesystem path: expand, then resolve the full symlink chain so it
  # agrees across file_read (resolves symlinks), file_write and multi_file_edit
  # (expand only) — resolution here makes them converge. Every filesystem
  # operation in this module (`stat/1`, `content_hash/2`) uses THIS path, not
  # the ledger key: a name's bytes are preserved verbatim by Linux filesystems,
  # so a read rescued to the on-disk NFD form must be stat'd under those same
  # bytes. NFC-normalising first would yield a path that does not exist on Linux
  # and the read would be silently dropped (#212).
  defp fs_path(path) do
    OptimalSystemAgent.Agent.Safety.PathCanon.canonicalize(path)
  end

  # The ledger key derived from an already-resolved `fs_path/1`: Unicode
  # NFC-normalised so a read recorded under one normalisation form (e.g. the NFD
  # name file_read rescued to on disk) is found by a lookup under the other (e.g.
  # the NFC name the model typed). macOS (APFS) collapses the two at the FS
  # layer; Linux preserves the bytes, so the ledger must normalise them itself —
  # otherwise the caller reads successfully and is then told it never read the
  # file. Falls back to the raw path if the bytes are not valid UTF-8 (a name is
  # arbitrary bytes), which at worst declines to unify the two forms.
  defp key_path(fspath) do
    case :unicode.characters_to_nfc_binary(fspath) do
      bin when is_binary(bin) -> bin
      _ -> fspath
    end
  end

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, mtime, size}
      _ -> :error
    end
  end

  defp epoch_key(session_id), do: {:__compaction_epoch__, skey(session_id)}

  # Above this, hashing costs more than the redundant read saves, and `file_read`
  # refuses a whole-file read of that size anyway. `nil` means "no basis to
  # suppress", which `read_status/3` turns into real content.
  @max_hash_bytes 8 * 1024 * 1024

  # Content hash of the file, or `nil` when it cannot be taken. `nil` is a
  # deliberate one-way value: it can only ever cause a real read, never a
  # suppression, because `read_status/3` matches `^rhash when not is_nil(rhash)`.
  defp content_hash(_path, size) when size > @max_hash_bytes, do: nil

  defp content_hash(path, _size) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_insert(key, entry) do
    :ets.insert(@table, {key, entry})
    :ok
  rescue
    ArgumentError ->
      # Table vanished between ensure_table/0 and the insert (owner crashed).
      ensure_table()

      try do
        :ets.insert(@table, {key, entry})
      rescue
        ArgumentError -> :ok
      end

      :ok
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  # Ensure the backing ETS table exists, starting the owner GenServer on first
  # use. GenServer.start blocks until init/1 (which creates the table) returns,
  # so once this call returns the table is guaranteed present.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _ -> ensure_ets()
        end

      _tid ->
        :ok
    end
  end

  # Create the table directly if it does not exist. Called from init/1 (owned by
  # the GenServer) and as a last-resort fallback.
  defp ensure_ets do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end
end
