defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.DriftGuard do
  @moduledoc """
  Hashline-style self-verifying edit guard (steal-list #6 / reconciliation U-A2:
  grok `xai-grok-tools/.../hashline`).

  `OptimalSystemAgent.Tools.FileState` already rejects an edit when the target
  file's on-disk `{mtime, size}` differs from what was recorded at the model's
  last `file_read` — that's the primary read-before-edit / stale-write guard.
  This module adds a second, independent content-hash guard *on top of* it,
  scoped entirely to `file_edit`, closing the one blind spot an `{mtime,
  size}` identity check can never see: two *different* files (or two
  different revisions of the same file) that happen to land on the exact
  same size in the exact same wall-clock second — `File.stat/2, time:
  :posix` mtime is second-resolution, so a hook / linter-on-save /
  concurrent sub-agent rewrite that reproduces both by coincidence (or by a
  test/attacker forcing it) sails straight through the mtime/size check.

  ## How it works — deliberately deferential to FileState

  After every successful `file_edit` write, `record/5` stores the resulting
  file's `{mtime, size}` *together with* a normalized content fingerprint,
  keyed by `{session, canonical_path}`. Before the *next* edit to that path
  in the same session, `verify/5`:

    * finds no baseline → **defer** (`:ok`, bootstrap — nothing to compare).
    * finds a baseline whose `{mtime, size}` **differs** from the file's
      current `{mtime, size}` → **defer** (`:ok`). The file's identity has
      genuinely moved on since our last edit (a fresh `file_read` + retry,
      or FileState's own mtime/size check already gated this transition —
      either it already rejected the edit, or it legitimately passed a real
      re-read). DriftGuard never second-guesses that: doing so would create
      a permanent lockout, since it never observes `file_read`.
    * finds a baseline whose `{mtime, size}` **matches** current →
      cross-check the content fingerprint. If it matches too, `:ok`. If it
      does **not** match, the file's identity looks unchanged but its bytes
      are not what we last wrote — the exact aliasing collision FileState's
      coarse check cannot see — **rejected** with a "re-read and retry"
      instruction.

  This means DriftGuard can only ever be *stricter* than FileState within
  the narrow window where FileState would otherwise wrongly say "unchanged."
  It never blocks an edit that FileState alone would allow via a real,
  distinguishable state transition.

  ## Normalization (robust to cosmetic noise)

  The fingerprint is computed over content with CRLF/CR normalized to LF and
  trailing whitespace stripped from every line, so a formatter pass that only
  touches line endings or trailing whitespace does not spuriously trip the
  guard — only edits that change actual line content do (while still being
  caught only within the exact-mtime/size collision window described above).
  This mirrors the same tolerance `FileEdit.Matcher`'s line-endings/whitespace
  fuzzy stages already apply when matching `old_string`.

  ## Scope

  Like `FileState`, the `nil` and `"test"` sentinel sessions are exempt (no
  session context to track — matches `UseContext.empty/0` used by the flat
  compat shim and pre-tracking unit tests).

  Storage: a self-owned, unsupervised ETS table
  (`:osa_file_edit_drift_guard`), the same self-owning-GenServer pattern
  `FileState` and the hook engine use. If the owner dies, the table is
  recreated on next use; the worst case is a single unnecessary bootstrap
  (never a corrupt write).
  """

  use GenServer

  @table :osa_file_edit_drift_guard

  # Sessions exempt from drift-guard enforcement — mirrors FileState's
  # @exempt_sessions so flat-shim / unit-test callers keep working unchanged.
  @exempt_sessions [nil, "test"]

  # FNV-1a 64-bit constants.
  @fnv_offset 0xCBF29CE484222325
  @fnv_prime 0x100000001B3
  @mask 0xFFFFFFFFFFFFFFFF

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
  Verify `path`'s current `content` (already read fresh from disk by the
  caller, alongside its `mtime`/`size`) against the baseline recorded after
  this session's last successful edit of `path`.

  Returns:
    * `:ok` — no baseline recorded yet (bootstrap), the file's `{mtime,
      size}` identity has moved on since the baseline (defer to FileState —
      see moduledoc), the content fingerprint matches, or the session is
      exempt.
    * `{:error, message}` — `{mtime, size}` is IDENTICAL to the recorded
      baseline but the content fingerprint is not: the file's identity looks
      unchanged but its bytes are not what this session last wrote.
  """
  @spec verify(term(), String.t(), String.t(), integer(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  def verify(session_id, path, content, mtime, size) do
    if enforce?(session_id) do
      ensure_table()
      key = {session_id, canonical(path)}

      case safe_lookup(key) do
        [{^key, %{mtime: ^mtime, size: ^size, fp: fp}}] ->
          if fp == fingerprint(content), do: :ok, else: {:error, drift_message(path)}

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Record `content` (post-write, already on disk, with its `mtime`/`size`) as
  the new baseline for `path` in `session_id`. No-op for exempt sessions.
  """
  @spec record(term(), String.t(), String.t(), integer(), non_neg_integer()) :: :ok
  def record(session_id, path, content, mtime, size) do
    if enforce?(session_id) do
      ensure_table()
      key = {session_id, canonical(path)}
      safe_insert(key, %{mtime: mtime, size: size, fp: fingerprint(content)})
    end

    :ok
  end

  @doc "True when `session_id` is subject to drift-guard enforcement."
  @spec enforce?(term()) :: boolean()
  def enforce?(session_id), do: session_id not in @exempt_sessions

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

  @doc """
  Whitespace/EOL-normalized FNV-1a 64-bit fingerprint of `content`. Exposed
  for tests and for callers that want to compare fingerprints directly.
  """
  @spec fingerprint(String.t()) :: non_neg_integer()
  def fingerprint(content) do
    content
    |> String.split(["\r\n", "\r", "\n"])
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> fnv1a()
  end

  # ── Messages (model-directed) ─────────────────────────────────────────

  defp drift_message(path) do
    "#{path} changed since you read it — its size and modification time look " <>
      "unchanged, but the content is not what this session last wrote (a hook, " <>
      "another tool, or a concurrent sub-agent rewrote it). " <>
      "File changed since you read it — re-read and retry."
  end

  # ── Internals ─────────────────────────────────────────────────────────

  defp canonical(path) do
    expanded = Path.expand(path)

    case :file.read_link_all(String.to_charlist(expanded)) do
      {:ok, real} ->
        real_str = to_string(real)
        if String.starts_with?(real_str, "/"), do: real_str, else: "/" <> real_str

      _ ->
        expanded
    end
  end

  defp fnv1a(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce(@fnv_offset, fn byte, hash ->
      Bitwise.band(Bitwise.bxor(hash, byte) * @fnv_prime, @mask)
    end)
  end

  defp safe_insert(key, fp) do
    :ets.insert(@table, {key, fp})
    :ok
  rescue
    ArgumentError ->
      ensure_table()

      try do
        :ets.insert(@table, {key, fp})
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
