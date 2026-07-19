defmodule OptimalSystemAgent.Agent.SessionPersistence.Jsonl do
  @moduledoc """
  Append-only JSONL storage mechanics for the immutable session event log.

  This is the storage half of OSA's **two-log** session persistence (P1 in
  `docs/steal-list.md`, modelled on grok-build's `session/storage/jsonl`):

    * `SessionPersistence` owns the **mutable** compaction-pruned transcript
      (`~/.osa/sessions/<id>.json`, rewritten crash-atomically every turn — the
      list actually resent to the model), and
    * this module owns the **immutable**, append-only event log
      (`~/.osa/sessions/<id>.updates.jsonl`) — the source of truth for
      replay/rewind that compaction NEVER touches.

  The split means compaction and rewind can never corrupt each other: shrinking
  the mutable transcript rewrites `<id>.json` and leaves `updates.jsonl` whole.

  ## Durability mechanics (ported from grok)

    * **Sidecar lock.** Every append serializes under an exclusive `.lock`
      sidecar (O_EXCL create — the BEAM-idiomatic equivalent of `flock`), so two
      writers (a hooks auto-save racing an HTTP save, a second backend) can't
      interleave a >PIPE_BUF line. A crashed holder's stale lock is broken by
      mtime age; if the lock can't be taken the append still proceeds
      best-effort (the torn-tail heal below bounds any damage).

    * **Torn-tail self-heal.** Appends are not crash-atomic: a kill / `ENOSPC`
      mid-write leaves a partial record with no trailing newline. Before every
      append we check the last byte and, if it isn't `\\n`, prepend one — so the
      torn record is terminated as its own single line. This bounds the damage of
      any torn write to exactly one line, which the reader then skips.

    * **O_APPEND.** Records are written with `:append`, so concurrent appends
      never truncate each other.

  ## Corruption tolerance (never brick a session)

  `read/1` splits on raw `\\n`, skips any unparseable line with a warning, and —
  the first time it sees corruption — copies the raw file to `*.corrupt` next to
  the original for offline recovery. Failing the whole load on one torn line
  would brick the session forever, which is strictly worse than resuming without
  the one damaged record.

  All functions are path-based (no session knowledge) so the module is reusable
  and unit-testable against a tempdir.
  """
  require Logger

  @lock_max_tries 50
  @lock_sleep_ms 10
  @lock_stale_secs 15

  @doc """
  Append `records` (a list of JSON-encodable maps) as newline-terminated JSONL
  lines to `path`, under the sidecar lock, healing a torn tail first.

  Best-effort and never raises: a write failure is logged and returned as
  `{:error, reason}` so the caller (a post-turn save) is never broken by the
  immutable log.
  """
  @spec append(String.t(), [map()]) :: :ok | {:error, term()}
  def append(_path, []), do: :ok

  def append(path, records) when is_list(records) do
    File.mkdir_p!(Path.dirname(path))

    data =
      records
      |> Enum.map(&(Jason.encode!(&1) <> "\n"))
      |> IO.iodata_to_binary()

    with_lock(path, fn ->
      heal_torn_tail(path)
      File.write!(path, data, [:append])
    end)

    :ok
  rescue
    e ->
      Logger.warning("[session_persist] JSONL append failed for #{path}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Read all JSONL records from `path`, tolerating corruption.

  Returns `{:ok, records, skipped}` where `skipped` counts unparseable lines that
  were dropped. Splits on raw `\\n` so a write torn mid-UTF-8 poisons only its own
  line. On the first detected corruption the raw file is preserved as
  `<path>.corrupt`. A missing file is an empty log, not an error.
  """
  @spec read(String.t()) :: {:ok, [map()], non_neg_integer()} | {:error, term()}
  def read(path) do
    if File.exists?(path) do
      contents = File.read!(path)

      {rev_records, skipped} =
        contents
        |> String.split("\n")
        |> Enum.reduce({[], 0}, fn line, {acc, skipped} ->
          case String.trim(line) do
            "" ->
              {acc, skipped}

            trimmed ->
              case Jason.decode(trimmed) do
                {:ok, record} -> {[record | acc], skipped}
                {:error, _} -> {acc, skipped + 1}
              end
          end
        end)

      if skipped > 0 do
        quarantine(path)

        Logger.warning(
          "[session_persist] skipped #{skipped} unparseable line(s) in #{path} " <>
            "(torn or interleaved append?); loaded #{length(rev_records)}, original " <>
            "preserved as *.corrupt"
        )
      end

      {:ok, Enum.reverse(rev_records), skipped}
    else
      {:ok, [], 0}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Delete the JSONL file and its `.lock` / `.corrupt` sidecars (best-effort)."
  @spec delete(String.t()) :: :ok
  def delete(path) do
    Enum.each([path, path <> ".lock", path <> ".corrupt"], fn p ->
      _ = File.rm(p)
    end)

    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Terminate a torn tail: if the file is non-empty and its last byte isn't a
  # newline, append one so the partial (crash-torn) record becomes its own
  # isolated line. MUST run under the append lock so the check-then-heal is
  # atomic w.r.t. other writers.
  defp heal_torn_tail(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        last = read_last_byte(path, size)

        if last != "\n" do
          Logger.warning("[session_persist] terminating torn JSONL tail in #{path}")
          File.write!(path, "\n", [:append])
        end

      _ ->
        :ok
    end
  end

  defp read_last_byte(path, size) do
    case :file.open(path, [:read, :binary]) do
      {:ok, fd} ->
        result =
          case :file.pread(fd, size - 1, 1) do
            {:ok, byte} -> byte
            _ -> "\n"
          end

        :file.close(fd)
        result

      _ ->
        "\n"
    end
  end

  # Preserve the raw (corrupt) file once, so the post-load rewrite of the mutable
  # transcript can't erase the only evidence. Never overwrites an existing
  # quarantine copy.
  defp quarantine(path) do
    q = path <> ".corrupt"

    unless File.exists?(q) do
      case File.cp(path, q) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[session_persist] quarantine copy failed: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # Exclusive sidecar lock via O_EXCL create. Retries with backoff, breaks a
  # stale lock by mtime age, and falls back to a best-effort lock-free append if
  # it still can't acquire (torn-tail heal keeps that safe).
  defp with_lock(path, fun) do
    lock = path <> ".lock"

    case acquire_lock(lock, @lock_max_tries) do
      {:ok, fd} ->
        try do
          fun.()
        after
          :file.close(fd)
          File.rm(lock)
        end

      :error ->
        Logger.warning("[session_persist] proceeding without lock on #{path} (contended)")
        fun.()
    end
  end

  defp acquire_lock(_lock, 0), do: :error

  defp acquire_lock(lock, tries) do
    case :file.open(lock, [:write, :exclusive, :binary]) do
      {:ok, fd} ->
        {:ok, fd}

      {:error, :eexist} ->
        maybe_break_stale(lock)
        Process.sleep(@lock_sleep_ms)
        acquire_lock(lock, tries - 1)

      {:error, _other} ->
        :error
    end
  end

  defp maybe_break_stale(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        if System.system_time(:second) - mtime > @lock_stale_secs do
          Logger.warning("[session_persist] breaking stale lock #{lock}")
          File.rm(lock)
        end

      _ ->
        :ok
    end
  end
end
