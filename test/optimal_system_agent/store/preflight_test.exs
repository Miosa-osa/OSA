defmodule OptimalSystemAgent.Store.PreflightTest do
  @moduledoc """
  Defect 1: `journal_mode: :wal` was *requested* in config and never read back.

  `PRAGMA journal_mode=WAL` is a request SQLite is allowed to decline (NFS/SMB/
  overlayfs have no usable shared memory for the `-shm` file), and the decline
  is silent — the store keeps working, just without WAL's crash-safety. There was
  also no integrity check and no read-only preflight, so a corrupt or read-only
  database surfaced as an opaque failure at the first write instead of at boot.

  These tests pin the readback and both failure classifications.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Store.Preflight

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, db: Path.join(dir, "store.db")}
  end

  # Independent readback, so the assertions below check the DATABASE, not just
  # that our own report agrees with itself.
  defp journal_mode(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "PRAGMA journal_mode")
    {:ok, [[mode] | _]} = Exqlite.Sqlite3.fetch_all(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    Exqlite.Sqlite3.close(conn)
    String.downcase(mode)
  end

  describe "journal-mode readback" do
    test "reports the mode SQLite actually settled on, not the one we asked for", %{db: db} do
      assert {:ok, report} = Preflight.check(db)

      assert report.wal? == true
      assert report.journal_mode == "wal"
      # The report is not self-referential: an independent connection sees it too.
      assert journal_mode(db) == "wal"
    end

    test "converts an existing non-WAL database and confirms the conversion", %{db: db} do
      # A store created before WAL was configured (or downgraded by a tool that
      # ran `PRAGMA journal_mode=DELETE`).
      {:ok, conn} = Exqlite.Sqlite3.open(db)
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=DELETE")
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (a INTEGER)")
      Exqlite.Sqlite3.close(conn)

      assert journal_mode(db) == "delete"

      assert {:ok, %{wal?: true, journal_mode: "wal"}} = Preflight.check(db)
      assert journal_mode(db) == "wal"
    end

    test "verify! returns the report and does not raise for a healthy store", %{db: db} do
      assert %{wal?: true, integrity: "ok", writable?: true} = Preflight.verify!(db)
    end
  end

  describe "integrity check" do
    test "a file that is not a SQLite database is diagnosed as corrupt", %{dir: dir} do
      path = Path.join(dir, "garbage.db")
      File.write!(path, :crypto.strong_rand_bytes(8192))

      assert {:error, {:corrupt, message}} = Preflight.check(path)
      assert message =~ path
      # The message must be actionable, not just "error".
      assert message =~ ".recover"
    end

    test "verify! raises with a clear message rather than deferring to first write", %{dir: dir} do
      path = Path.join(dir, "garbage2.db")
      File.write!(path, :crypto.strong_rand_bytes(8192))

      assert_raise RuntimeError, ~r/preflight failed \(corrupt\)/, fn ->
        Preflight.verify!(path)
      end
    end

    test "the :warn policy downgrades a raise to a log", %{dir: dir} do
      path = Path.join(dir, "garbage3.db")
      File.write!(path, :crypto.strong_rand_bytes(8192))

      prior = Application.get_env(:optimal_system_agent, :store_preflight)
      Application.put_env(:optimal_system_agent, :store_preflight, :warn)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:optimal_system_agent, :store_preflight, prior),
          else: Application.delete_env(:optimal_system_agent, :store_preflight)
      end)

      assert Preflight.verify!(path) == nil
    end
  end

  describe "read-only preflight" do
    @tag :tmp_dir
    test "a database in a non-writable directory fails at boot, not at first write", %{
      dir: dir,
      db: db
    } do
      # SQLite needs to create `-wal`/`-shm`/journal files NEXT TO the database,
      # so a writable file in a read-only directory is still not usable.
      {:ok, conn} = Exqlite.Sqlite3.open(db)
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (a INTEGER)")
      Exqlite.Sqlite3.close(conn)

      File.chmod!(db, 0o444)
      File.chmod!(dir, 0o555)
      on_exit(fn -> File.chmod(dir, 0o755) end)

      if root?() do
        # root ignores the permission bits; the probe cannot be constructed.
        assert {:ok, _} = Preflight.check(db)
      else
        assert {:error, {:readonly, message}} = Preflight.check(db)
        assert message =~ db
        assert message =~ "not writable"
      end
    end
  end

  describe "Repo.init/2 durability options" do
    test "pins WAL, a busy_timeout and synchronous=FULL", %{db: db} do
      assert {:ok, config} =
               OptimalSystemAgent.Store.Repo.init(:supervisor, database: db, pool_size: 1)

      assert config[:journal_mode] == :wal

      # ecto_sqlite3 defaults synchronous to NORMAL, which under WAL fsyncs only
      # at checkpoint — a power loss can lose the most recently committed turns.
      assert config[:synchronous] == :full

      # Concurrent writers from other `osa` processes must WAIT for SQLite's
      # single-writer lock, not immediately get SQLITE_BUSY.
      assert config[:custom_pragmas][:busy_timeout] == 5000
      assert config[:custom_pragmas][:encoding] == "'UTF-8'"
    end

    test "init runs the preflight, so a corrupt store fails at boot", %{dir: dir} do
      path = Path.join(dir, "corrupt-at-boot.db")
      File.write!(path, :crypto.strong_rand_bytes(8192))

      assert_raise RuntimeError, ~r/preflight failed/, fn ->
        OptimalSystemAgent.Store.Repo.init(:supervisor, database: path, pool_size: 1)
      end
    end
  end

  defp root? do
    case System.cmd("id", ["-u"]) do
      {out, 0} -> String.trim(out) == "0"
      _ -> false
    end
  end
end
