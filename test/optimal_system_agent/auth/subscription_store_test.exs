defmodule OptimalSystemAgent.Auth.SubscriptionStoreTest do
  @moduledoc """
  The credential store's job is to hold a bearer token for someone's paid
  account without ever exposing it to other users of the machine, and without
  two OSA processes destroying it by refreshing at once. These tests assert
  exactly those two properties, plus the read-only contract that keeps status
  displays from mutating anything.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.SubscriptionStore

  setup do
    # Redirect the store at a scratch home so the suite can never read or
    # clobber the operator's real ~/.osa/subscriptions.json.
    dir = Path.join(System.tmp_dir!(), "osa-substore-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev, do: System.put_env("OSA_HOME", prev), else: System.delete_env("OSA_HOME")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  describe "storage permissions" do
    test "the credential file is created 0600 and never exists at a wider mode" do
      assert :ok = SubscriptionStore.put("copilot", %{"access_token" => "secret"})

      {:ok, stat} = File.stat(SubscriptionStore.path())
      mode = Bitwise.band(stat.mode, 0o777)

      assert mode == 0o600,
             "credential file is mode #{Integer.to_string(mode, 8)}; a bearer token for a paid " <>
               "account must never be readable by other local users"
    end

    test "no temp file is left behind after a write" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "secret"})

      leftovers =
        SubscriptionStore.path()
        |> Path.dirname()
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".tmp"))

      assert leftovers == []
    end

    test "a world-readable credential file is REFUSED, not silently used" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "secret"})
      File.chmod!(SubscriptionStore.path(), 0o644)

      # Silently reading it would mean OSA keeps working while every local user
      # can lift the token — the failure would be invisible precisely when it
      # matters most.
      assert SubscriptionStore.fetch("copilot") == nil
      refute SubscriptionStore.connected?("copilot")
    end
  end

  describe "round trip" do
    test "stores and reads back an entry" do
      entry = %{"access_token" => "at", "refresh_token" => "rt", "expires_at" => 123}
      assert :ok = SubscriptionStore.put("copilot", entry)

      assert %{"access_token" => "at", "refresh_token" => "rt"} = SubscriptionStore.fetch("copilot")
      assert SubscriptionStore.connected?("copilot")
    end

    test "keeps providers independent" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "a"})
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "b"})

      assert SubscriptionStore.fetch("copilot")["access_token"] == "a"
      assert SubscriptionStore.fetch("openai_codex")["access_token"] == "b"
      assert map_size(SubscriptionStore.list()) == 2
    end

    test "missing / absent credentials read as nil rather than raising" do
      assert SubscriptionStore.fetch("copilot") == nil
      assert SubscriptionStore.list() == %{}
      refute SubscriptionStore.connected?("copilot")
    end

    test "a corrupt credential file degrades to 'not connected' instead of crashing" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "a"})
      File.write!(SubscriptionStore.path(), "{not json")
      File.chmod!(SubscriptionStore.path(), 0o600)

      assert SubscriptionStore.fetch("copilot") == nil
    end
  end

  describe "delete" do
    test "removes one provider and is idempotent" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "a"})
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "b"})

      assert :ok = SubscriptionStore.delete("copilot")
      assert SubscriptionStore.fetch("copilot") == nil
      assert SubscriptionStore.fetch("openai_codex")["access_token"] == "b"

      # Signing out twice must not be an error.
      assert :ok = SubscriptionStore.delete("copilot")
    end

    test "removes the file entirely once the last credential is gone" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "a"})
      assert :ok = SubscriptionStore.delete("copilot")

      refute File.exists?(SubscriptionStore.path()),
             "an empty credential file still advertises that this machine had subscriptions"
    end
  end

  describe "refresh under lock" do
    test "adopts a token a peer already rotated instead of spending its own" do
      # This is the double-refresh bug the lock exists to prevent: refresh
      # tokens are single-use, so if two processes both POST, the second
      # invalidates the whole grant and the user is silently signed out.
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "old", "refresh_token" => "r1"})

      refreshed? = :counters.new(1, [])

      result =
        SubscriptionStore.refresh_within_lock(
          "copilot",
          fn _entry ->
            :counters.add(refreshed?, 1, 1)
            {:ok, %{"access_token" => "new"}}
          end,
          # Simulate "by the time we hold the lock, the on-disk token is fresh".
          fn _entry -> false end
        )

      assert {:ok, entry} = result
      assert entry["access_token"] == "old"

      assert :counters.get(refreshed?, 1) == 0,
             "must not spend a refresh token when the on-disk copy is already current"
    end

    test "refreshes and persists when the stored token really is stale" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "old", "refresh_token" => "r1"})

      assert {:ok, entry} =
               SubscriptionStore.refresh_within_lock(
                 "copilot",
                 fn e -> {:ok, Map.put(e, "access_token", "new")} end,
                 fn _ -> true end
               )

      assert entry["access_token"] == "new"
      assert SubscriptionStore.fetch("copilot")["access_token"] == "new"
    end

    test "a failed refresh leaves the existing credential intact" do
      # A flaky network must never destroy a working sign-in.
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "old", "refresh_token" => "r1"})

      assert {:error, :boom} =
               SubscriptionStore.refresh_within_lock(
                 "copilot",
                 fn _ -> {:error, :boom} end,
                 fn _ -> true end
               )

      assert SubscriptionStore.fetch("copilot")["access_token"] == "old"
    end

    test "refreshing an unconnected provider reports it rather than crashing" do
      assert {:error, :not_connected} =
               SubscriptionStore.refresh_within_lock("copilot", fn e -> {:ok, e} end, fn _ -> true end)
    end

    test "the file the refresh writes is still 0600" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "old", "refresh_token" => "r1"})

      {:ok, _} =
        SubscriptionStore.refresh_within_lock(
          "copilot",
          fn e -> {:ok, Map.put(e, "access_token", "new")} end,
          fn _ -> true end
        )

      {:ok, stat} = File.stat(SubscriptionStore.path())
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end
  end

  describe "cross-process lock" do
    test "serialises concurrent read-modify-write so no update is lost" do
      :ok = SubscriptionStore.put("copilot", %{"n" => 0})

      # 20 concurrent increments. Without the lock these interleave and the
      # final count comes out short.
      1..20
      |> Task.async_stream(
        fn _ ->
          SubscriptionStore.with_lock(fn ->
            current = SubscriptionStore.fetch("copilot")["n"]
            # Widen the read-modify-write window so an unlocked implementation
            # reliably loses updates rather than passing by luck.
            Process.sleep(2)
            all = SubscriptionStore.list()
            entry = Map.put(all["copilot"], "n", current + 1)
            File.write!(SubscriptionStore.path(), Jason.encode!(%{"version" => 1, "providers" => %{"copilot" => entry}}))
            File.chmod!(SubscriptionStore.path(), 0o600)
          end)
        end,
        max_concurrency: 20,
        timeout: 60_000
      )
      |> Stream.run()

      assert SubscriptionStore.fetch("copilot")["n"] == 20
    end

    test "releases the lock even when the critical section raises" do
      assert_raise RuntimeError, fn ->
        SubscriptionStore.with_lock(fn -> raise "boom" end)
      end

      # A lock leaked by a crash would wedge every later refresh.
      assert SubscriptionStore.with_lock(fn -> :ok end) == :ok
    end

    # The test above runs 20 tasks in ONE BEAM, which proves in-process
    # serialisation and nothing else — the module's headline claim is that the
    # lock holds across separate OS processes, because OSA genuinely runs as a
    # daemon plus a CLI plus mix tasks against one home directory, and an
    # in-VM mutex would not help there at all.
    #
    # This spawns real `elixir` processes. It is skipped rather than failed
    # when no `elixir` binary is reachable (some packaged CI images run the
    # suite from a release), because an unrunnable test that fails is
    # indistinguishable from a broken lock.
    @tag :tmp_dir
    test "the lock genuinely excludes a SEPARATE OS PROCESS", %{dir: dir} do
      elixir = System.find_executable("elixir")

      if is_nil(elixir) do
        # Recorded explicitly: silence here would look like a pass.
        IO.puts("\n  [skip] no `elixir` on PATH — cross-OS-process lock test not run")
      else
        lock = SubscriptionStore.path() <> ".lock"
        File.mkdir_p!(Path.dirname(lock))
        marker = Path.join(dir, "peer-entered")

        # A second OS process that takes the lock the same way this module
        # does — O_CREAT|O_EXCL on the same path — holds it, then releases.
        script = Path.join(dir, "peer.exs")

        File.write!(script, """
        lock = #{inspect(lock)}
        marker = #{inspect(marker)}

        case File.open(lock, [:write, :exclusive]) do
          {:ok, io} ->
            IO.binwrite(io, "peer-token 0 peer")
            File.close(io)
            File.write!(marker, "held")
            Process.sleep(1500)
            File.rm(lock)

          {:error, reason} ->
            File.write!(marker, "failed: " <> inspect(reason))
        end
        """)

        peer = Task.async(fn -> System.cmd(elixir, [script], stderr_to_stdout: true) end)

        # Wait for the peer to actually hold it before racing for it.
        wait_for = fn wait_for, n ->
          cond do
            File.exists?(marker) -> :ok
            n > 200 -> :timeout
            true -> Process.sleep(25) && wait_for.(wait_for, n + 1)
          end
        end

        assert wait_for.(wait_for, 0) == :ok, "peer process never acquired the lock"
        assert File.read!(marker) == "held"

        started = System.monotonic_time(:millisecond)
        assert SubscriptionStore.with_lock(fn -> :entered end) == :entered
        waited = System.monotonic_time(:millisecond) - started

        assert waited > 500,
               "acquired the lock while another OS PROCESS held it — the lock is not " <>
                 "cross-process at all (waited only #{waited}ms)"

        Task.await(peer, 30_000)
      end
    end

    # The stale-lock breaker is necessary (a crashed holder must not wedge every
    # future refresh) but on its own it is unsafe: if the holder was slow rather
    # than dead, breaking its lock creates two live holders and the loser
    # overwrites the winner — with the OLDER credential, which can resurrect a
    # token the winner already rotated away. The ownership token is what turns
    # that silent clobber into a clean, reportable failure.
    test "a holder whose lock was broken abandons its write instead of clobbering the winner" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "original"})

      result =
        SubscriptionStore.with_lock(fn token ->
          assert SubscriptionStore.still_holding?(token)

          # Simulate exactly what the stale-breaker does to a slow holder: the
          # lock is taken over by somebody else mid-flight.
          File.write!(SubscriptionStore.path() <> ".lock", "somebody-elses-token 0 999")

          refute SubscriptionStore.still_holding?(token),
                 "a holder must be able to detect that its lock was taken"

          :observed
        end)

      assert result == :observed

      # The impostor lock is still there, and that is correct: removing a lock
      # this process no longer owns would hand a third process a lock the
      # second still believes it holds. Clear it here so the next assertion
      # starts from a clean slate rather than a `:lock_timeout`.
      File.rm(SubscriptionStore.path() <> ".lock")

      # And the refresh path acts on that detection rather than writing anyway.
      #
      # It abandons the WRITE, not the token. `refresh_fun` returning `{:ok, _}`
      # means the refresh POST already completed, so for a rotating provider the
      # token this call spent is gone; dropping the replacement on the floor
      # left the caller with nothing and a dead credential on disk. The loser
      # therefore still receives its rotation (and uses it for the live
      # session) — it simply does not persist it over the winner's.
      outcome =
        SubscriptionStore.refresh_within_lock(
          "copilot",
          fn entry ->
            File.write!(SubscriptionStore.path() <> ".lock", "stolen-by-a-peer 0 999")
            {:ok, Map.put(entry, "access_token", "stale-loser-value")}
          end,
          fn _ -> true end
        )

      assert outcome == {:ok, %{"access_token" => "stale-loser-value"}},
             "a consumed rotation must reach the caller even when it cannot be persisted"

      assert SubscriptionStore.fetch("copilot")["access_token"] == "original",
             "the losing write must not land"

      # `:lock_lost` remains a first-class, retryable outcome elsewhere in the
      # auth surface, and is reported as what it is — a race, never as a
      # credential problem that sends the user back through a sign-in.
      message = OptimalSystemAgent.Auth.Subscription.message(:lock_lost, "GitHub Copilot")
      assert message =~ "Retry"
      refute message =~ "sign in again"

      File.rm(SubscriptionStore.path() <> ".lock")
    end
  end

  # Every write in this module is a WHOLE-FILE rewrite of the map a read
  # returned. That makes "what does a failed read return?" a data-destruction
  # question, not an ergonomics one: a read that degrades to `%{}` hands the
  # writer a map asserting that every provider is disconnected, and the writer
  # then makes that true on disk.
  #
  # The corruption tests above only ever assert `fetch == nil`. Neither of them
  # WRITES after a corrupt read, which is precisely why a whole-store wipe
  # lived here undetected — the read half was loud and correct, and the write
  # half quietly destroyed the file anyway. These tests write.
  describe "a degraded read can never reach a whole-file writer" do
    test "put/2 refuses rather than wiping every other provider after an unreadable store" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "a"})
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "b"})

      # One `chmod 0644` — from a hand edit, a restore, a permissive umask.
      File.chmod!(SubscriptionStore.path(), 0o644)

      assert {:error, {:unsafe_read, :insecure_permissions}} =
               SubscriptionStore.put("xai", %{"access_token" => "c"})

      # The pre-existing credentials must still be on disk, byte for byte. On
      # the original code this single `put` rewrote the file from `%{}` and
      # both other subscriptions were gone forever.
      File.chmod!(SubscriptionStore.path(), 0o600)

      assert SubscriptionStore.fetch("copilot")["access_token"] == "a"
      assert SubscriptionStore.fetch("openai_codex")["access_token"] == "b"
      assert map_size(SubscriptionStore.list()) == 2
    end

    test "put/2 refuses after a truncated/corrupt store and leaves the bytes untouched" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "a"})
      File.write!(SubscriptionStore.path(), "{not json")
      File.chmod!(SubscriptionStore.path(), 0o600)

      assert {:error, {:unsafe_read, _}} = SubscriptionStore.put("xai", %{"access_token" => "c"})

      # Refusing keeps the damaged file available for recovery. Overwriting it
      # would have destroyed whatever a partial write had left recoverable.
      assert File.read!(SubscriptionStore.path()) == "{not json"
    end

    test "delete/1 does not unlink the whole store when the read failed" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "a"})
      :ok = SubscriptionStore.put("openai_codex", %{"access_token" => "b"})
      File.chmod!(SubscriptionStore.path(), 0o644)

      # The original `delete/1` computed `remaining = Map.delete(%{}, id)`,
      # saw `map_size == 0`, and `File.rm`'d the entire credential file —
      # signing the user out of every provider because of a mode bit.
      assert {:error, {:unsafe_read, :insecure_permissions}} = SubscriptionStore.delete("copilot")

      assert File.exists?(SubscriptionStore.path()),
             "an unreadable store must never be deleted as though it were empty"

      File.chmod!(SubscriptionStore.path(), 0o600)
      assert map_size(SubscriptionStore.list()) == 2
    end

    test "refresh_within_lock/3 reports an unreadable store instead of calling it 'not connected'" do
      :ok = SubscriptionStore.put("copilot", %{"access_token" => "old", "refresh_token" => "r1"})
      File.chmod!(SubscriptionStore.path(), 0o644)

      called? = :counters.new(1, [])

      result =
        SubscriptionStore.refresh_within_lock(
          "copilot",
          fn e ->
            :counters.add(called?, 1, 1)
            {:ok, e}
          end,
          fn _ -> true end
        )

      # `:not_connected` (what the old code returned, because `fetch/1`
      # collapses every failure to `nil`) tells the caller to sign in again —
      # destructive advice for a file that is merely mis-permissioned.
      assert {:error, {:unsafe_read, :insecure_permissions}} = result
      assert :counters.get(called?, 1) == 0, "must not spend a refresh token against a store it could not read"

      File.chmod!(SubscriptionStore.path(), 0o600)
      assert SubscriptionStore.fetch("copilot")["access_token"] == "old"
    end
  end

  describe "store version" do
    test "a file written by a newer OSA is refused, not silently downgraded to v1" do
      future =
        Jason.encode!(%{
          "version" => 99,
          "providers" => %{"copilot" => %{"access_token" => "a", "some_future_field" => "keep me"}}
        })

      File.mkdir_p!(Path.dirname(SubscriptionStore.path()))
      File.write!(SubscriptionStore.path(), future)
      File.chmod!(SubscriptionStore.path(), 0o600)

      # The writer has always stamped `"version"`; the reader ignored it
      # entirely, which made the field decoration rather than a contract.
      assert SubscriptionStore.fetch("copilot") == nil

      assert {:error, {:unsafe_read, {:unsupported_version, 99}}} =
               SubscriptionStore.put("xai", %{"access_token" => "c"})

      # The original code re-serialised the whole store at v1 here, dropping
      # every field this binary has no code for — including, plausibly, the
      # refresh token of a provider it does not know about.
      assert File.read!(SubscriptionStore.path()) == future
    end

    test "a v1 file, and one with no version key at all, still read" do
      File.mkdir_p!(Path.dirname(SubscriptionStore.path()))

      for body <- [
            Jason.encode!(%{"version" => 1, "providers" => %{"copilot" => %{"access_token" => "a"}}}),
            Jason.encode!(%{"providers" => %{"copilot" => %{"access_token" => "a"}}})
          ] do
        File.write!(SubscriptionStore.path(), body)
        File.chmod!(SubscriptionStore.path(), 0o600)
        assert SubscriptionStore.fetch("copilot")["access_token"] == "a"
      end
    end
  end

  describe "path stability" do
    test "the path is resolved once per lock, not per call" do
      # `path/0` reads OSA_HOME on every call, and the read, the lock and the
      # rename each used to call it independently. A home directory that
      # changes mid-operation therefore locked one file and wrote another —
      # an unlocked write, to a store nobody had read.
      original = SubscriptionStore.path()
      elsewhere = Path.join(System.tmp_dir!(), "osa-substore-moved-#{System.unique_integer([:positive])}")

      observed =
        SubscriptionStore.with_lock(fn ctx ->
          System.put_env("OSA_HOME", elsewhere)
          ctx
        end)

      System.put_env("OSA_HOME", Path.dirname(original))

      assert observed.path == original,
             "the body must operate on the path the lock was taken against"

      assert observed.lock == original <> ".lock",
             "the lockfile must sit beside the file it protects, not beside a later OSA_HOME"

      File.rm_rf(elsewhere)
    end
  end
end
