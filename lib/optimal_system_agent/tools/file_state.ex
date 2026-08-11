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
  """

  use GenServer
  require Logger

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

  Idempotent and best-effort — a stat failure (file vanished between read and
  record) is silently ignored rather than raised.
  """
  @spec record_read(term(), String.t()) :: :ok
  def record_read(session_id, path) do
    ensure_table()
    key = {skey(session_id), canonical(path)}

    case stat(canonical(path)) do
      {:ok, mtime, size} ->
        entry = %{mtime: mtime, size: size, read_at: System.system_time(:second)}
        safe_insert(key, entry)

      :error ->
        :ok
    end
  end

  @doc """
  Refresh the read-state entry after a successful write, so a subsequent edit
  to the same file in the same turn is not flagged stale. Equivalent to
  re-recording the current on-disk state as "read".
  """
  @spec record_write(term(), String.t()) :: :ok
  def record_write(session_id, path), do: record_read(session_id, path)

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
      cpath = canonical(path)
      key = {skey(session_id), cpath}

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
    key = {skey(session_id), canonical(path)}
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

  # Canonical absolute path: expand, then resolve the full symlink chain so the
  # key agrees across file_read (resolves symlinks), file_write and
  # multi_file_edit (expand only) — resolution here makes them converge.
  defp canonical(path), do: OptimalSystemAgent.Agent.Safety.PathCanon.canonicalize(path)

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, mtime, size}
      _ -> :error
    end
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
