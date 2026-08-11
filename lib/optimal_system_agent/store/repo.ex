defmodule OptimalSystemAgent.Store.Repo do
  use Ecto.Repo,
    otp_app: :optimal_system_agent,
    adapter: Ecto.Adapters.SQLite3

  alias OptimalSystemAgent.Store.Preflight

  @doc """
  Runtime init callback — pins the durability-relevant options and VERIFIES the
  ones SQLite is allowed to silently decline.

  Three things happen here, all before the pool opens a single connection:

    * **UTF-8 pragma.** Set in `config.exs` too, but re-injected so it survives
      any environment override (e.g. `config/test.exs` replacing the keyword
      list wholesale).

    * **`busy_timeout`.** Makes concurrent writers *wait* for SQLite's
      single-writer lock (up to 5s) instead of immediately returning
      `SQLITE_BUSY`. This is what keeps the multi-process story (every `osa`
      invocation opens its own pool against the same file) from turning into
      dropped turns — see the boundary note below.

    * **`synchronous = FULL`.** `ecto_sqlite3` defaults to `NORMAL`, which under
      WAL fsyncs only at checkpoint — process-crash safe, but a power loss or
      kernel panic can lose the most recently committed transactions. FULL
      fsyncs the WAL on every commit. We pay one fsync per commit and buy "a
      committed turn is actually on disk"; OSA's store writes at turn/tool
      cadence, not OLTP rates, so the throughput cost is not observable.

    * **Preflight.** `Preflight.verify!/1` opens the database file directly and
      checks that it is writable, structurally intact (`PRAGMA quick_check`),
      and — critically — that `PRAGMA journal_mode` *reads back* as `wal`.
      Requesting WAL is not the same as getting it (see `Preflight`).

  ## Cross-process boundary — read this before assuming safety

  Every `osa` invocation starts its own BEAM with its own connection pool
  against the same `osa.db`. There is no cross-process coordination beyond what
  SQLite itself provides. What that actually gives you:

    * **Guaranteed.** WAL + `busy_timeout` means concurrent writers from
      different OS processes *serialize* rather than error: one writer holds the
      write lock, the other blocks up to 5s and then proceeds. Readers never
      block writers. Single statements and single transactions are atomic across
      processes.

    * **NOT guaranteed.** Read-modify-write sequences spanning multiple
      statements are not isolated across processes unless they run inside one
      `BEGIN IMMEDIATE` transaction, and a writer that waits out the full 5s
      still fails with `SQLITE_BUSY`. There is no leader election, no advisory
      lock, and no attempt to make two concurrently running `osa` processes
      agree on session state at the SQLite layer. Session *transcripts* are
      protected separately — see `Agent.SessionPersistence`, which serializes
      its own record writes with an O_EXCL sidecar lock and detects foreign
      writers via a `rev`/`writer` stamp.

  We state this rather than implying a stronger guarantee: running several
  concurrent `osa` processes against one store is *safe from corruption*, not
  *serializable*.
  """
  @impl true
  def init(_type, config) do
    existing = Keyword.get(config, :custom_pragmas, [])

    pragmas =
      existing
      |> Keyword.put_new(:encoding, "'UTF-8'")
      |> Keyword.put_new(:busy_timeout, 5000)

    config =
      config
      |> Keyword.put(:custom_pragmas, pragmas)
      |> Keyword.put_new(:journal_mode, :wal)
      |> Keyword.put_new(:synchronous, :full)

    _ = maybe_preflight(Keyword.get(config, :database))

    {:ok, config}
  end

  # Only meaningful for a real file-backed database. `:memory:` (and a missing
  # path, which happens for some mix tasks) has nothing to preflight.
  defp maybe_preflight(path) when is_binary(path) and path != "" and path != ":memory:" do
    Preflight.verify!(path)
  end

  defp maybe_preflight(_), do: nil
end
