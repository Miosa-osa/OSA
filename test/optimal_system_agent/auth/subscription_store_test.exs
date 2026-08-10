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
  end
end
