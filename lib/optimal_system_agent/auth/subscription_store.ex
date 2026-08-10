defmodule OptimalSystemAgent.Auth.SubscriptionStore do
  @moduledoc """
  On-disk store for *account* credentials — the tokens OSA holds when a user
  connects a provider subscription instead of pasting an API key.

  Lives at `~/.osa/subscriptions.json` (override the directory with `OSA_HOME`),
  mode `0600`, one entry per provider id.

  ## Why this is not `~/.osa/.env`, and not the CredentialPool

  An API key is a string the user can copy back out of a password manager. A
  refresh token is a **long-lived bearer credential for a paid account** that
  the user cannot scope per project and often cannot even see. It rotates, it
  expires, and it is spent under mutual exclusion. That is a different storage
  contract, so it gets a different file.

  It is deliberately NOT stored in `Providers.CredentialPool`. That module
  snapshots its view at boot and has historically outranked freshly-written
  config — the bug where a stale snapshot shadowed a key the user had just
  entered. `reload/0` exists but is not called from every write path. A
  subscription token is *mutated by other OS processes* (a second `osa`, a mix
  task, the daemon) far more often than a key is, so a boot snapshot is exactly
  the wrong shape. Everything here is **read live off disk, under lock**, the
  same discipline `Onboarding.live_env/1` already applies to `.env`.

  ## Concurrency: why the lock is load-bearing, not defensive

  OAuth refresh tokens are **single-use and rotating**. If two OSA processes
  notice an expiring token at the same moment and both POST the refresh, the
  second exchange presents an already-spent token and the provider invalidates
  the whole grant — the user is silently signed out, and the only visible
  symptom is a 401 on their next message.

  So every read-modify-write goes through `with_lock/1`, and the refresh path
  is required to **re-read under the lock immediately before spending a
  token** and *adopt* a token another process already rotated rather than
  spending its own stale copy (`refresh_within_lock/3`). In-process
  serialisation alone is not sufficient here; OSA genuinely runs as several OS
  processes against one home directory.

  ## Read-only vs mutating

  `fetch/1` and `list/0` are **pure reads and never touch the network** — so
  `osa doctor`, `osa auth status` and model-list rendering can call them
  freely without triggering a token refresh (or a refresh *failure*) as a side
  effect of merely displaying state. Only `refresh_within_lock/3` and `put/2`
  mutate.
  """

  require Logger

  @filename "subscriptions.json"
  @lock_suffix ".lock"
  @version 1

  # A refresh POST plus retries; well under any turn timeout. If a peer holds
  # the lock longer than this it has almost certainly died mid-refresh, so we
  # break the lock rather than wedging the user's session forever.
  @lock_timeout_ms 30_000
  @lock_stale_ms 60_000
  @lock_poll_ms 50

  @type entry :: %{optional(String.t()) => term()}

  # ── Paths ────────────────────────────────────────────────────────────────

  defp osa_dir, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")

  @doc "Absolute path of the credential file."
  @spec path() :: String.t()
  def path, do: Path.join(osa_dir(), @filename)

  defp lock_path, do: path() <> @lock_suffix

  # ── Reads (never network, never mutate) ──────────────────────────────────

  @doc """
  Read one provider's stored credential, or `nil`.

  Pure read. Returns `nil` — never raises — for every failure mode (no file,
  unparseable file, unreadable home directory), because a missing credential
  and a broken credential are the same thing from a caller's point of view:
  this provider is not connected.
  """
  @spec fetch(String.t() | atom()) :: entry() | nil
  def fetch(provider_id) do
    read_all() |> Map.get(to_string(provider_id))
  end

  @doc "All stored credentials, keyed by provider id. Pure read."
  @spec list() :: %{optional(String.t()) => entry()}
  def list, do: read_all()

  @doc "True when a provider has a stored account credential."
  @spec connected?(String.t() | atom()) :: boolean()
  def connected?(provider_id), do: not is_nil(fetch(provider_id))

  defp read_all do
    file = path()

    with true <- File.regular?(file),
         :ok <- check_permissions(file),
         {:ok, body} <- File.read(file),
         {:ok, %{"providers" => providers}} when is_map(providers) <- Jason.decode(body) do
      providers
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  # Refuse to load a group/world-readable credential file, LOUDLY.
  #
  # Silently using it would mean OSA keeps working while every other local user
  # can read a bearer token for the operator's paid account — the failure is
  # invisible precisely when it matters. Refusing turns it into "reconnect this
  # provider", which is a 10-second fix with a clear cause.
  defp check_permissions(file) do
    case File.stat(file) do
      {:ok, %File.Stat{mode: mode}} ->
        # Low 6 bits = group + other. Anything set is a leak.
        if Bitwise.band(mode, 0o077) == 0 do
          :ok
        else
          Logger.warning(
            "[Auth] Refusing to read #{file}: it is readable by other users on this machine " <>
              "(mode #{Integer.to_string(Bitwise.band(mode, 0o777), 8)}). " <>
              "Delete it and reconnect the provider, or run: chmod 600 #{file}"
          )

          {:error, :insecure_permissions}
        end

      other ->
        other
    end
  end

  # ── Writes ───────────────────────────────────────────────────────────────

  @doc """
  Store (or replace) one provider's credential, atomically and at 0600.

  Takes the cross-process lock, so a concurrent writer cannot lose an update.
  """
  @spec put(String.t() | atom(), entry()) :: :ok | {:error, term()}
  def put(provider_id, entry) when is_map(entry) do
    with_lock(fn ->
      all = read_all()
      write_all(Map.put(all, to_string(provider_id), stringify(entry)))
    end)
  end

  @doc """
  Remove one provider's credential — the storage half of "sign out".

  Returns `:ok` whether or not anything was there, so logout is idempotent and
  a user who is already signed out never sees an error.
  """
  @spec delete(String.t() | atom()) :: :ok | {:error, term()}
  def delete(provider_id) do
    with_lock(fn ->
      all = read_all()
      remaining = Map.delete(all, to_string(provider_id))

      if map_size(remaining) == 0 do
        # Don't leave an empty credential file lying around advertising that
        # this machine once had subscriptions configured.
        _ = File.rm(path())
        :ok
      else
        write_all(remaining)
      end
    end)
  end

  # Atomic, 0600-from-birth write.
  #
  # NEVER `File.write!` then `File.chmod!`. That is a real TOCTOU hole, not a
  # theoretical one: between the two calls the file exists at the process
  # umask (commonly 0644) with the token already in it, and any local process
  # can read it. Writing a 0600 temp file in the SAME directory and renaming
  # over the target means the credential is never observable at a permissive
  # mode, and readers only ever see a complete file (rename is atomic within a
  # filesystem) rather than a half-written one.
  defp write_all(providers) do
    file = path()
    dir = Path.dirname(file)
    File.mkdir_p!(dir)

    body = Jason.encode!(%{"version" => @version, "providers" => providers})
    tmp = Path.join(dir, ".#{@filename}.#{:erlang.unique_integer([:positive])}.tmp")

    try do
      # :exclusive fails if the path exists — no clobbering a peer's temp file.
      {:ok, io} = File.open(tmp, [:write, :binary, :exclusive])

      try do
        # chmod BEFORE the secret is written.
        :ok = File.chmod(tmp, 0o600)
        IO.binwrite(io, body)
        # Durability: a token that survived the prompt but not a power cut
        # would present as a mysterious silent logout.
        _ = :file.sync(io)
      after
        File.close(io)
      end

      :ok = File.rename(tmp, file)
      # Also sync the DIRECTORY, or the rename itself can be lost.
      sync_dir(dir)
      :ok
    rescue
      e ->
        _ = File.rm(tmp)
        {:error, e}
    end
  end

  defp sync_dir(dir) do
    case :file.open(String.to_charlist(dir), [:read]) do
      {:ok, io} ->
        _ = :file.sync(io)
        :file.close(io)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # ── Cross-process advisory lock ──────────────────────────────────────────

  @doc """
  Run `fun` holding the store's cross-process lock.

  Implemented as an exclusively-created lockfile beside the store, which is
  the one primitive that behaves consistently across the filesystems OSA runs
  on. A lock older than #{@lock_stale_ms}ms is broken and taken: a stale lock
  is always the corpse of a crashed process, and the alternative — refusing to
  refresh forever — is a worse outcome than a rare double refresh.
  """
  @spec with_lock((-> result)) :: result | {:error, :lock_timeout} when result: term()
  def with_lock(fun) when is_function(fun, 0) do
    lock = lock_path()
    File.mkdir_p!(Path.dirname(lock))

    case acquire(lock, System.monotonic_time(:millisecond)) do
      :ok ->
        try do
          fun.()
        after
          _ = File.rm(lock)
        end

      {:error, _} = err ->
        err
    end
  end

  defp acquire(lock, started_at) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        # Record the holder so a human debugging a wedged lock can see who has
        # it. No secrets — pid and timestamp only.
        IO.binwrite(io, "#{System.system_time(:second)} #{System.pid()}")
        File.close(io)
        :ok

      {:error, :eexist} ->
        cond do
          stale?(lock) ->
            _ = File.rm(lock)
            acquire(lock, started_at)

          System.monotonic_time(:millisecond) - started_at > @lock_timeout_ms ->
            {:error, :lock_timeout}

          true ->
            Process.sleep(@lock_poll_ms)
            acquire(lock, started_at)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale?(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        System.system_time(:second) - mtime > div(@lock_stale_ms, 1000)

      _ ->
        false
    end
  end

  # ── Refresh under lock (the reason the lock exists) ──────────────────────

  @doc """
  Refresh a provider's token without ever spending a rotated refresh token.

  The sequence matters and is the whole point:

    1. take the lock
    2. **re-read the entry from disk** — a peer process may have refreshed
       while we were waiting, in which case its token is already on disk
    3. if the freshly-read entry is no longer expiring, **adopt it** and make
       no network call at all
    4. otherwise call `refresh_fun` with the fresh entry, and persist whatever
       it returns

  Step 3 is what prevents the double-refresh that invalidates the grant. A
  naive implementation reads once, waits on the lock, then refreshes the copy
  it read *before* waiting — which is precisely the stale token a peer just
  replaced.

  `refresh_fun` receives the current entry and returns `{:ok, new_entry}` or
  `{:error, reason}`. Errors are passed through untouched and nothing is
  written, so a transient network failure never destroys a working credential.
  """
  @spec refresh_within_lock(String.t() | atom(), (entry() -> {:ok, entry()} | {:error, term()}), (entry() ->
                                                                                                    boolean())) ::
          {:ok, entry()} | {:error, term()}
  def refresh_within_lock(provider_id, refresh_fun, needs_refresh?)
      when is_function(refresh_fun, 1) and is_function(needs_refresh?, 1) do
    with_lock(fn ->
      case fetch(provider_id) do
        nil ->
          {:error, :not_connected}

        fresh ->
          if needs_refresh?.(fresh) do
            case refresh_fun.(fresh) do
              {:ok, updated} ->
                all = read_all()
                merged = Map.put(all, to_string(provider_id), stringify(updated))

                case write_all(merged) do
                  :ok -> {:ok, updated}
                  err -> err
                end

              {:error, _} = err ->
                err
            end
          else
            # A peer already rotated it. Adopt, do not spend.
            {:ok, fresh}
          end
      end
    end)
  end
end
