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

  # Deliberately larger than the worst case a LIVE holder can take, which is
  # what it was not before: a refresh POST carries `receive_timeout: 30_000`
  # and may be retried, so a perfectly healthy holder could exceed 60s and
  # have its lock stolen mid-flight — and a stolen lock during a refresh is
  # exactly the double-spend of a single-use rotating refresh token that this
  # whole module exists to prevent. Stealing is still possible for a genuinely
  # dead holder, just no longer possible for a slow one.
  @lock_stale_ms 180_000
  @lock_poll_ms 50

  @type entry :: %{optional(String.t()) => term()}

  @typedoc """
  What a `with_lock/1` body is handed: the store path resolved once at
  acquisition, the lockfile beside it, and this holder's ownership token.
  """
  @type ctx :: %{path: String.t(), lock: String.t(), token: String.t()}

  # ── Paths ────────────────────────────────────────────────────────────────

  defp osa_dir, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")

  @doc "Absolute path of the credential file."
  @spec path() :: String.t()
  def path, do: Path.join(osa_dir(), @filename)

  # `path/0` reads `OSA_HOME` on EVERY call, so two calls inside one
  # read-modify-write can disagree — a home directory changed between lock
  # acquisition and rename would lock one file and write another, which is
  # both an unlocked write and a write to a store nobody read. Everything
  # inside `with_lock/1` therefore threads the single path captured at
  # acquisition (see the `ctx` map) rather than calling `path/0` again.
  defp lock_path(file), do: file <> @lock_suffix

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

  defp read_all(file \\ path()) do
    case read_state(file) do
      {:ok, providers} -> providers
      {:error, _} -> %{}
    end
  end

  @doc """
  Read the whole store, distinguishing "empty" from "could not be read".

  This distinction is the difference between a working store and a wiped one.
  Every write here is a **whole-file rewrite** of the map a read returned, so
  a read that degrades to `%{}` on failure hands the writer a map that claims
  every other provider is disconnected. One `chmod 0644`, one truncated JSON
  from a crash, one unreadable home directory — plus one routine token
  refresh on any single provider — and every other subscription on the
  machine is silently discarded, by a code path whose read half logged a loud
  warning and whose write half then destroyed the file anyway.

  So the failure never reaches a writer as data:

    * `{:ok, providers}` — the file was absent (an empty store, which IS a
      safe base for the first write) or was read and validated in full.
    * `{:error, reason}` — permissions, IO, malformed JSON, or a version this
      binary does not understand. Callers that write MUST abort.

  Reads that only display state (`fetch/1`, `list/0`) still collapse errors
  to "not connected", because from a caller's point of view a missing
  credential and a broken one are the same thing. Writers must not.
  """
  @spec read_state(String.t()) :: {:ok, %{optional(String.t()) => entry()}} | {:error, term()}
  def read_state(file \\ path()) do
    if File.regular?(file) do
      with :ok <- check_permissions(file),
           {:ok, body} <- File.read(file),
           {:ok, decoded} <- Jason.decode(body) do
        extract_providers(decoded)
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unreadable, other}}
      end
    else
      # No file at all is not a failure: it is an empty store, and it is the
      # only "degraded" read a writer may safely build on.
      {:ok, %{}}
    end
  rescue
    e -> {:error, e}
  catch
    _, reason -> {:error, reason}
  end

  # Validate the envelope, INCLUDING the version the writer stamps.
  #
  # `write_all/2` has always written `"version" => 1` and the reader always
  # ignored it, which made the field decoration rather than a contract: an
  # older binary reading a file written by a newer one saw only the keys it
  # recognised, and `put/2`'s whole-file rewrite then re-serialised the store
  # at v1 — permanently dropping every field the old binary did not
  # understand, including, plausibly, the refresh token of a provider it had
  # no code for. Refusing to read a future version turns a silent downgrade
  # into "this file was written by a newer OSA", which is recoverable.
  #
  # Older versions get a migration hook here. There is only v1 today, so the
  # hook is the identity, but the branch is where a v0 -> v1 upgrade goes.
  defp extract_providers(%{"providers" => providers} = decoded) when is_map(providers) do
    case Map.get(decoded, "version", @version) do
      v when is_integer(v) and v == @version ->
        {:ok, providers}

      v when is_integer(v) and v < @version ->
        migrate(v, providers)

      v ->
        Logger.warning(
          "[Auth] #{path()} was written by a newer OSA (store version #{inspect(v)}, this " <>
            "binary understands #{@version}). Refusing to read or rewrite it rather than " <>
            "silently dropping fields it contains. Upgrade OSA, or delete the file and " <>
            "reconnect your providers."
        )

        {:error, {:unsupported_version, v}}
    end
  end

  defp extract_providers(_), do: {:error, :malformed}

  # No older on-disk versions exist yet; this is where they would be upgraded.
  defp migrate(_version, providers), do: {:ok, providers}

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
    with_lock(fn ctx ->
      case read_state(ctx.path) do
        {:ok, all} ->
          write_all(ctx.path, Map.put(all, to_string(provider_id), stringify(entry)))

        {:error, reason} ->
          refuse_write(provider_id, ctx.path, reason)
      end
    end)
  end

  # A write derived from a read that failed is a wipe. Refuse it, loudly.
  #
  # The caller gets an error instead of a false `:ok`, so a sign-in reports
  # "could not be saved" rather than appearing to succeed while it silently
  # deleted every other provider on the way through.
  defp refuse_write(provider_id, file, reason) do
    Logger.error(
      "[Auth] #{provider_id}: refusing to write #{file} because the existing store could not " <>
        "be read (#{inspect(reason)}). Writing now would rewrite the whole file from an empty " <>
        "map and discard every other connected provider. Fix the file first — usually " <>
        "`chmod 600 #{file}`, or delete it and reconnect."
    )

    {:error, {:unsafe_read, reason}}
  end

  @doc """
  Remove one provider's credential — the storage half of "sign out".

  Returns `:ok` whether or not anything was there, so logout is idempotent and
  a user who is already signed out never sees an error.
  """
  @spec delete(String.t() | atom()) :: :ok | {:error, term()}
  def delete(provider_id) do
    with_lock(fn ctx ->
      case read_state(ctx.path) do
        {:ok, all} ->
          remaining = Map.delete(all, to_string(provider_id))

          if map_size(remaining) == 0 do
            # Don't leave an empty credential file lying around advertising
            # that this machine once had subscriptions configured. Safe only
            # because the read SUCCEEDED and genuinely returned nothing else —
            # on a failed read this branch used to unlink the entire store on
            # the strength of a `%{}` that meant "unreadable", not "empty".
            _ = File.rm(ctx.path)
            :ok
          else
            write_all(ctx.path, remaining)
          end

        {:error, reason} ->
          refuse_write(provider_id, ctx.path, reason)
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
  defp write_all(file, providers) do
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
  on. `fun` receives the lock's **ownership token** — an opaque string that is
  also the lockfile's contents — so a long-running body can ask
  `still_holding?/1` before it writes.

  ## Breaking a stale lock, and why that needs a second mechanism

  A lock older than #{@lock_stale_ms}ms is broken and taken, because a stale
  lock is normally the corpse of a crashed process and refusing to refresh
  forever is worse than a rare double refresh.

  But "normally" is doing real work in that sentence, and on its own it is not
  safe: if the original holder is merely slow rather than dead, breaking its
  lock produces two live holders, and the loser then overwrites the winner —
  silently, with the older of the two credentials. That is worse than the
  deadlock it was avoiding, because the losing write can resurrect a token the
  winner has already had rotated out from under it.

  So the lock is **re-validated before every write**, not only acquired. The
  holder stamps a token nobody else can guess into the lockfile;
  `still_holding?/1` re-reads it, and a mismatch means the lock was broken and
  this process must abandon its write rather than complete it. The window is
  not eliminated — that would need a filesystem primitive not portably
  available — but it is narrowed from "the whole body" to "between the check
  and the rename", and the failure mode changes from a silent clobber to a
  write this process declines to make. (In `refresh_within_lock/3` that means
  it skips the write and logs — it still hands the caller the rotation it
  already spent a token to obtain; see that function's docs.)
  """
  @spec with_lock((-> result) | (ctx() -> result)) ::
          result | {:error, :lock_timeout}
        when result: term()
  def with_lock(fun) when is_function(fun, 0) or is_function(fun, 1) do
    # Resolve the store path ONCE, here, and thread it through the body. An
    # `OSA_HOME` that changes mid-operation must not be able to make the body
    # write a different file than the one this lock protects.
    file = path()
    lock = lock_path(file)
    File.mkdir_p!(Path.dirname(lock))

    token = mint_token()
    ctx = %{path: file, lock: lock, token: token}

    case acquire(lock, token, System.monotonic_time(:millisecond)) do
      :ok ->
        try do
          if is_function(fun, 1), do: fun.(ctx), else: fun.()
        after
          # Only remove a lock we still own. Removing one that has been broken
          # and re-taken would hand a third process a lock the second still
          # thinks it holds.
          if still_holding?(ctx), do: File.rm(lock)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  True when the lockfile still contains this process's ownership token.

  Cheap (one small read) and meant to be called immediately before a write, so
  a holder whose lock was broken as stale aborts instead of overwriting
  whoever took it.
  """
  @spec still_holding?(ctx()) :: boolean()
  def still_holding?(%{lock: lock, token: token}) when is_binary(token) do
    case File.read(lock) do
      {:ok, contents} -> String.contains?(contents, token)
      _ -> false
    end
  rescue
    _ -> false
  end

  # 128 bits of CSPRNG. Not a secret — the lockfile is 0600-adjacent and holds
  # nothing sensitive — but it must be unguessable enough that two holders
  # cannot collide, and a pid is not: pids are reused, and OSA runs in
  # containers where two processes genuinely can share one.
  defp mint_token, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp acquire(lock, token, started_at) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        # Ownership token first, then human-readable provenance so somebody
        # debugging a wedged lock can see who has it. No secrets.
        IO.binwrite(io, "#{token} #{System.system_time(:second)} #{System.pid()}")
        File.close(io)
        :ok

      {:error, :eexist} ->
        cond do
          stale?(lock) ->
            _ = File.rm(lock)
            acquire(lock, token, started_at)

          System.monotonic_time(:millisecond) - started_at > @lock_timeout_ms ->
            {:error, :lock_timeout}

          true ->
            Process.sleep(@lock_poll_ms)
            acquire(lock, token, started_at)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Judged on mtime, which is a wall-clock quantity and therefore vulnerable to
  # a backwards clock step making a stale lock look fresh forever. That is
  # survivable ONLY because `@lock_timeout_ms` bounds how long a waiter blocks
  # regardless — a waiter that never sees the lock go stale still gives up with
  # `:lock_timeout` rather than waiting indefinitely. There is no portable
  # monotonic timestamp to put on a file.
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

  ## Once the exchange has happened, the new token is never dropped

  A `{:ok, new_entry}` means the refresh POST completed, which for a rotating
  provider means the token that was on disk is now **spent**. `new_entry` is
  from that moment the only working credential in existence, so this function
  returns `{:ok, new_entry}` even when persisting it fails or the store lock
  turned out to have been broken. It retries the write and logs loudly, but a
  disk error is reported through the log — never by throwing away the
  credential. (Returning `{:error, ...}` there is what turned a transient write
  failure into "your account is signed out, re-run setup": the caller lost the
  new token and the spent one stayed on disk to fail `:refresh_token_invalid`
  forever after.)
  """
  @spec refresh_within_lock(
          String.t() | atom(),
          (entry() -> {:ok, entry()} | {:error, term()}),
          (entry() ->
             boolean())
        ) ::
          {:ok, entry()} | {:error, term()}
  def refresh_within_lock(provider_id, refresh_fun, needs_refresh?)
      when is_function(refresh_fun, 1) and is_function(needs_refresh?, 1) do
    with_lock(fn ctx ->
      # Re-read under the lock from the SAME path the lock protects, and keep
      # the error: an unreadable store must not present as "not connected"
      # here either, because the branch below it writes.
      case read_state(ctx.path) do
        {:error, reason} ->
          {:error, {:unsafe_read, reason}}

        {:ok, all} ->
          refresh_fresh_entry(
            ctx,
            provider_id,
            Map.get(all, to_string(provider_id)),
            all,
            refresh_fun,
            needs_refresh?
          )
      end
    end)
  end

  defp refresh_fresh_entry(ctx, provider_id, fresh, all, refresh_fun, needs_refresh?) do
    case fresh do
      nil ->
        {:error, :not_connected}

      fresh ->
        if needs_refresh?.(fresh) do
          case refresh_fun.(fresh) do
            {:ok, updated} ->
              # PAST THE POINT OF NO RETURN. The refresh POST has already
              # gone out and come back, so for a rotating-refresh-token
              # provider the token still on disk is SPENT — it can never be
              # exchanged again. From here `updated` is the only working
              # credential that exists anywhere, and it must reach the caller
              # no matter what the disk does.
              #
              # The lock check still governs whether we WRITE (a lock we no
              # longer hold means somebody else took over and our copy may be
              # the older one, so writing it would undo their work) — but not
              # whether we RETURN. Failing to persist costs a re-refresh next
              # boot; failing to return costs the grant.
              if still_holding?(ctx) do
                # `all` is the map read under THIS lock a moment ago and
                # already known-good — re-reading here would reintroduce the
                # very "read failed, so rewrite the file from `%{}`" wipe this
                # module now refuses to perform.
                merged = Map.put(all, to_string(provider_id), stringify(updated))
                persist_rotated(provider_id, ctx.path, merged)
              else
                Logger.error(
                  "[Auth] #{provider_id}: the store lock was broken while a refresh was in " <>
                    "flight, so the rotated token was NOT written (a peer's credential is on " <>
                    "disk and must not be clobbered). Returning it to the live session; it " <>
                    "will be re-refreshed on the next start."
                )
              end

              {:ok, updated}

            {:error, _} = err ->
              # Nothing was spent — the exchange never completed — so the
              # on-disk token is still good. Pass the error through untouched.
              err
          end
        else
          # A peer already rotated it. Adopt, do not spend.
          {:ok, fresh}
        end
    end
  end

  # Persist a rotation that has ALREADY been consumed.
  #
  # Retries, because the alternative to a retry here is a destroyed grant: the
  # old token is spent, so if this write never lands the user is silently
  # signed out and has to re-run setup. A duplicate/late write is recoverable;
  # this is not. Never raises, and never decides the caller's return value —
  # the token goes back regardless.
  @persist_attempts 3
  @persist_retry_ms 25

  defp persist_rotated(provider_id, file, merged, attempt \\ 1) do
    case write_all(file, merged) do
      :ok ->
        :ok

      {:error, reason} when attempt < @persist_attempts ->
        Logger.warning(
          "[Auth] #{provider_id}: could not persist a freshly rotated token " <>
            "(#{inspect(reason)}) — retry #{attempt}/#{@persist_attempts - 1}"
        )

        Process.sleep(@persist_retry_ms)
        persist_rotated(provider_id, file, merged, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "[Auth] #{provider_id}: a token rotation SUCCEEDED but could not be written to " <>
            "#{path()} after #{@persist_attempts} attempts (#{inspect(reason)}). The previous " <>
            "refresh token is spent, so the credential on disk is now dead. This session keeps " <>
            "working with the in-memory token; fix the disk (permissions/space) or re-run " <>
            "`osa login #{provider_id}` before restarting."
        )

        {:error, reason}
    end
  end
end
