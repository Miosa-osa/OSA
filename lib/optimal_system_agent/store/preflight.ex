defmodule OptimalSystemAgent.Store.Preflight do
  @moduledoc """
  Startup verification for the SQLite store, run once from `Store.Repo.init/2`
  before the connection pool is opened.

  ## Why this exists

  `config/config.exs` *asks* for `journal_mode: :wal`. Asking is not getting.
  `PRAGMA journal_mode=WAL` is a **request**: SQLite silently falls back to the
  DELETE journal when the database lives somewhere WAL cannot work — NFS, SMB,
  some overlayfs/containerd layers — because WAL needs shared memory (`-shm`)
  and real `mmap`/POSIX locking. The fallback is not an error; the pragma just
  returns `delete` and every later write behaves as if WAL had never been asked
  for. That removes WAL's crash-safety in exactly the environments where
  crashes and half-written pages are *most* likely, and nothing in the system
  ever noticed.

  Nothing read the pragma back, so this module does:

    1. **Read-only preflight.** Attempt a real (semantically no-op) write —
       rewriting `PRAGMA user_version` to its current value. A database on a
       read-only mount, or one whose directory is not writable (SQLite needs to
       create `-wal`/`-shm`/journal *next to* the file), fails here with a
       message naming the path, instead of surfacing as a cryptic
       `attempt to write a readonly database` at the first turn save.

    2. **Integrity check.** `PRAGMA quick_check` — the cheap sibling of
       `integrity_check` (skips the O(n log n) index-content cross-check, keeps
       page/row structural validation). A corrupt store is reported at boot
       rather than as a random query failure hours in.

    3. **Journal-mode readback.** Set WAL, then read `PRAGMA journal_mode` back
       and compare. A mismatch is logged at `:error` with the resolved path and
       the likely cause, because it is a genuine durability downgrade the
       operator can act on (move `~/.osa` to a local disk).

  ## Failure policy

  Read-only and corrupt databases **raise** — they are unusable and failing at
  boot with a clear message beats failing at the first write with an opaque one.
  A non-WAL journal mode does **not** raise: the store still works, it is just
  less crash-safe, and refusing to boot would strand users whose home directory
  is on a network mount. Set `config :optimal_system_agent, store_preflight:
  :warn` to downgrade the raising cases to warnings (escape hatch for recovery),
  or `:off` to skip preflight entirely.

  ## Durability trade-off (`synchronous`)

  `ecto_sqlite3` defaults `synchronous` to `NORMAL`. Under WAL, `NORMAL` fsyncs
  only at checkpoint: a process crash is safe (the WAL is still on disk), but a
  **power loss or kernel panic can lose the most recently committed
  transactions**. `Store.Repo` therefore pins `synchronous: :full`, which fsyncs
  the WAL on every commit. The cost is one fsync per commit; OSA's store writes
  at turn/tool cadence (a handful per second at worst), not at OLTP rates, so
  the throughput we give up is not observable, while the thing we buy — a
  committed turn actually being on the platter — is the entire point of the
  store.
  """
  require Logger

  @type report :: %{
          database: String.t(),
          journal_mode: String.t() | nil,
          wal?: boolean(),
          integrity: String.t() | nil,
          writable?: boolean()
        }

  @doc """
  Run the full preflight against `path`.

  Returns `{:ok, report}` when the database is writable, structurally intact and
  (possibly) in WAL mode — `report.wal?` tells you which. Returns
  `{:error, {reason, message}}` for a read-only or corrupt database, or when the
  file cannot be opened at all.

  Pure with respect to the schema: it creates the file if missing (SQLite would
  anyway) and creates the containing directory, but writes no rows.
  """
  @spec check(String.t()) :: {:ok, report()} | {:error, {atom(), String.t()}}
  def check(path) when is_binary(path) do
    _ = File.mkdir_p(Path.dirname(path))

    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} ->
        try do
          run_checks(conn, path)
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error,
         {:unopenable,
          "cannot open SQLite database at #{path}: #{inspect(reason)}. " <>
            "Check that the path exists and is readable."}}
    end
  end

  @doc """
  Run `check/1` and apply the failure policy: log the outcome, raise on a
  read-only or corrupt store (unless `store_preflight` is `:warn`), and never
  raise for a non-WAL journal mode. Returns the report (or `nil` when skipped).
  """
  @spec verify!(String.t()) :: report() | nil
  def verify!(path) when is_binary(path) do
    case policy() do
      :off ->
        nil

      policy ->
        case check(path) do
          {:ok, report} ->
            log_journal_mode(report)
            report

          {:error, {reason, message}} ->
            if policy == :warn do
              Logger.error("[store] preflight FAILED (#{reason}): #{message}")
              nil
            else
              raise RuntimeError,
                message:
                  "OSA store preflight failed (#{reason}): #{message}\n" <>
                    "Set `config :optimal_system_agent, store_preflight: :warn` to boot anyway."
            end
        end
    end
  end

  def verify!(_), do: nil

  # ── Private ──────────────────────────────────────────────────────────

  defp run_checks(conn, path) do
    # Integrity first: a file that is not a database at all fails EVERY pragma,
    # and "corrupt" is the accurate diagnosis. Running the writability probe
    # first would report that same file as read-only, sending the operator after
    # mount options for a problem that is data corruption.
    with :ok <- integrity(conn, path),
         :ok <- writable(conn, path) do
      mode = set_and_read_journal_mode(conn)

      {:ok,
       %{
         database: path,
         journal_mode: mode,
         wal?: mode == "wal",
         integrity: "ok",
         writable?: true
       }}
    end
  end

  # A semantically-neutral write: read user_version, write the SAME value back.
  # This exercises the exact machinery a real write needs (writable file AND a
  # writable parent directory for the rollback journal / -wal / -shm) without
  # touching any schema or data.
  defp writable(conn, path) do
    with {:ok, [[version]]} <- query(conn, "PRAGMA user_version"),
         :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA user_version = #{version}") do
      :ok
    else
      other ->
        {:error,
         {:readonly,
          "SQLite database at #{path} is not writable (#{inspect(other)}). " <>
            "The file AND its directory must be writable — SQLite creates " <>
            "`#{Path.basename(path)}-wal` / `-shm` next to it. Check mount " <>
            "options and ownership of #{Path.dirname(path)}."}}
    end
  end

  defp integrity(conn, path) do
    case query(conn, "PRAGMA quick_check") do
      {:ok, [["ok"] | _]} ->
        :ok

      {:ok, rows} ->
        detail = rows |> Enum.take(5) |> Enum.map_join("; ", &Enum.join(&1, " "))

        {:error,
         {:corrupt,
          "SQLite quick_check failed for #{path}: #{detail}. " <>
            "Move the file aside (a fresh store will be created) or recover it " <>
            "with `sqlite3 #{path} .recover`."}}

      other ->
        # quick_check itself failing means the file is not a readable database at
        # all (wrong format, truncated header, encrypted). Same remediation.
        {:error,
         {:corrupt,
          "SQLite quick_check could not run on #{path}: #{inspect(other)}. " <>
            "The file is not a readable SQLite database. Move it aside (a fresh " <>
            "store will be created) or recover it with `sqlite3 #{path} .recover`."}}
    end
  end

  # Ask for WAL, then READ IT BACK. The readback is the whole point: the request
  # can be silently declined (see @moduledoc). Runs on this preflight connection,
  # but journal mode is a property of the DATABASE FILE, not the connection, so
  # the pool's connections inherit whatever is established here.
  defp set_and_read_journal_mode(conn) do
    _ = query(conn, "PRAGMA journal_mode = WAL")

    case query(conn, "PRAGMA journal_mode") do
      {:ok, [[mode] | _]} when is_binary(mode) -> String.downcase(mode)
      _ -> nil
    end
  end

  defp log_journal_mode(%{wal?: true, database: path}) do
    Logger.debug("[store] journal_mode=wal verified for #{path}")
    :ok
  end

  defp log_journal_mode(%{journal_mode: mode, database: path}) do
    Logger.error(
      "[store] DURABILITY DOWNGRADE: journal_mode is #{inspect(mode)}, not \"wal\", for " <>
        "#{path}. WAL was requested and SILENTLY DECLINED — this happens on NFS/SMB/" <>
        "overlayfs mounts, where SQLite cannot create the shared-memory `-shm` file. " <>
        "Writes are now rollback-journalled: a crash mid-write can leave the store " <>
        "inconsistent, and concurrent readers block writers. Move the OSA data directory " <>
        "to a local filesystem to restore crash-safety."
    )

    :ok
  end

  defp query(conn, sql) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          Exqlite.Sqlite3.fetch_all(conn, stmt)
        after
          Exqlite.Sqlite3.release(conn, stmt)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp policy do
    case Application.get_env(:optimal_system_agent, :store_preflight, :strict) do
      :off -> :off
      :warn -> :warn
      _ -> :strict
    end
  end
end
