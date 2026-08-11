defmodule OptimalSystemAgent.Auth.SubscriptionRefreshPersistenceTest do
  @moduledoc """
  A disk failure after a *successful* OAuth refresh must not destroy the
  credential.

  `refresh_within_lock/3` calls `refresh_fun`, and a `{:ok, updated}` from it
  means the refresh POST already went out and came back. For a rotating
  refresh-token provider — which is most of them — the token still sitting on
  disk at that moment is **spent**. It cannot be exchanged again.

  The old code then did `case write_all(merged) do :ok -> {:ok, updated}; err ->
  err end`, and returned `{:error, :lock_lost}` when the lock had been broken
  underneath it. Both paths **dropped `updated`**: the caller got an error, the
  live session had no token, and the consumed token stayed on disk so the next
  attempt failed `:refresh_token_invalid` and the user had to re-run setup.

  A duplicate write is recoverable. A destroyed grant is not — so a rotation
  that has been consumed must always be handed back to the caller.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.SubscriptionStore

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-refresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev, do: System.put_env("OSA_HOME", prev), else: System.delete_env("OSA_HOME")
      # The write-failure test parks a directory at the store path.
      File.rm_rf(dir)
    end)

    :ok = SubscriptionStore.put("copilot", %{"refresh_token" => "old-rt", "expires_at" => 0})

    %{dir: dir}
  end

  defp rotated,
    do: %{"refresh_token" => "new-rt", "access_token" => "new-at", "expires_at" => 999}

  # Fail the atomic rename by parking a DIRECTORY at the store path. Deterministic,
  # and independent of the running user's privileges (unlike a chmod).
  defp break_the_disk! do
    File.rm_rf!(SubscriptionStore.path())
    File.mkdir_p!(SubscriptionStore.path())
  end

  test "a write failure after a consumed rotation still returns the new token" do
    result =
      SubscriptionStore.refresh_within_lock(
        "copilot",
        fn _fresh ->
          # The refresh POST has already succeeded at this point; `old-rt` is spent.
          break_the_disk!()
          {:ok, rotated()}
        end,
        fn _ -> true end
      )

    assert {:ok, updated} = result,
           "persistence failed AFTER a successful rotation and the new token was dropped — " <>
             "the spent token is all that remains and the account is signed out"

    assert updated["refresh_token"] == "new-rt"
    assert updated["access_token"] == "new-at"
  end

  test "a lock lost after a consumed rotation still returns the new token" do
    result =
      SubscriptionStore.refresh_within_lock(
        "copilot",
        fn _fresh ->
          # Simulate our stale lock being broken and re-taken by a peer.
          File.write!(SubscriptionStore.path() <> ".lock", "someone-elses-token 0 0")
          {:ok, rotated()}
        end,
        fn _ -> true end
      )

    assert {:ok, updated} = result,
           "the rotation was consumed and then thrown away because the lock had been broken"

    assert updated["refresh_token"] == "new-rt"
  end

  test "a lock lost does NOT clobber the peer's stored credential" do
    SubscriptionStore.refresh_within_lock(
      "copilot",
      fn _fresh ->
        # A peer took the lock and wrote its own, newer rotation. Written by
        # hand rather than via `put/2` because the store's lock is not
        # reentrant and we are already inside it.
        File.write!(
          SubscriptionStore.path(),
          Jason.encode!(%{
            "version" => 1,
            "providers" => %{"copilot" => %{"refresh_token" => "peer-rt"}}
          })
        )

        File.chmod!(SubscriptionStore.path(), 0o600)
        File.write!(SubscriptionStore.path() <> ".lock", "someone-elses-token 0 0")
        {:ok, rotated()}
      end,
      fn _ -> true end
    )

    assert SubscriptionStore.fetch("copilot")["refresh_token"] == "peer-rt",
           "a process whose lock was broken overwrote the winner's credential"
  end

  test "a healthy refresh still persists and returns the rotation" do
    assert {:ok, updated} =
             SubscriptionStore.refresh_within_lock(
               "copilot",
               fn _fresh -> {:ok, rotated()} end,
               fn _ -> true end
             )

    assert updated["refresh_token"] == "new-rt"
    assert SubscriptionStore.fetch("copilot")["refresh_token"] == "new-rt"
  end

  test "a FAILED refresh POST is still passed through untouched and writes nothing" do
    assert {:error, :boom} =
             SubscriptionStore.refresh_within_lock(
               "copilot",
               fn _fresh -> {:error, :boom} end,
               fn _ -> true end
             )

    assert SubscriptionStore.fetch("copilot")["refresh_token"] == "old-rt",
           "a transient network failure must never destroy a working credential"
  end
end
