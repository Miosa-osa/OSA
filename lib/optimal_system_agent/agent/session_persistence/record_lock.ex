defmodule OptimalSystemAgent.Agent.SessionPersistence.RecordLock do
  @moduledoc """
  Cross-process exclusive lock for a session record file.

  `SessionPersistence.save/3` is a read-modify-write: it reads `<id>.json` (to
  carry legacy metadata and to learn the current revision), builds a new record,
  and installs it with a temp-file + `rename/2`. `rename/2` is atomic *per call*
  but says nothing about the sequence — two OSA OS processes (every `osa`
  invocation is its own BEAM, and the HTTP channel, hooks and Guardian all save
  too) can interleave read/read/write/write and the second `rename` silently
  discards the first writer's turns.

  This module supplies the missing mutual exclusion using the same O_EXCL
  sidecar mechanism as `Jsonl` — the BEAM-idiomatic stand-in for `flock`, and
  the only one that works *across OS processes* (a GenServer mutex would only
  cover one node, which is precisely not where the exposure is).

  ## What it guarantees, and what it does not

    * `with_lock/2` runs `fun` with no other lock-respecting writer inside the
      same critical section, on the same filesystem, on the same host.
    * A holder that crashes leaves a stale lock; it is broken by mtime age
      (15s) so a crash cannot wedge a session forever.
    * Acquisition is bounded. If the lock still cannot be taken, `with_lock/2`
      returns `{:contended, result}` after running `fun` anyway — callers that
      care (i.e. `save/3`) pair this with the `rev`/`writer` conflict check, so
      a lock-free window still cannot *silently* lose turns.
    * It does **not** work across machines sharing a network filesystem where
      `O_EXCL` create is not atomic (old NFSv2/v3 without proper locking). We do
      not claim otherwise.
  """
  require Logger

  @max_tries 100
  @sleep_ms 5
  @stale_secs 15

  @doc """
  Run `fun` under the exclusive lock for `path`.

  Returns `{:ok, result}` when the lock was held for the whole call, or
  `{:contended, result}` when the lock could not be acquired and `fun` ran
  without it.
  """
  @spec with_lock(String.t(), (-> term())) :: {:ok, term()} | {:contended, term()}
  def with_lock(path, fun) when is_function(fun, 0) do
    lock = lock_path(path)
    _ = File.mkdir_p(Path.dirname(lock))

    case acquire(lock, @max_tries) do
      {:ok, fd} ->
        try do
          {:ok, fun.()}
        after
          :file.close(fd)
          File.rm(lock)
        end

      :error ->
        Logger.warning(
          "[session_persist] could not acquire record lock #{lock} — proceeding " <>
            "unlocked; a concurrent write will be detected by the rev stamp"
        )

        {:contended, fun.()}
    end
  end

  @doc "Lock sidecar path for a record path."
  @spec lock_path(String.t()) :: String.t()
  def lock_path(path), do: path <> ".lock"

  defp acquire(_lock, 0), do: :error

  defp acquire(lock, tries) do
    case :file.open(lock, [:write, :exclusive, :binary]) do
      {:ok, fd} ->
        {:ok, fd}

      {:error, :eexist} ->
        maybe_break_stale(lock)
        Process.sleep(@sleep_ms)
        acquire(lock, tries - 1)

      {:error, _other} ->
        :error
    end
  end

  defp maybe_break_stale(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        if System.system_time(:second) - mtime > @stale_secs do
          Logger.warning("[session_persist] breaking stale record lock #{lock}")
          File.rm(lock)
        end

      _ ->
        :ok
    end
  end
end
