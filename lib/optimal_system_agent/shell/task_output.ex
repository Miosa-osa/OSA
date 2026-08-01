defmodule OptimalSystemAgent.Shell.TaskOutput do
  @moduledoc """
  Per-task on-disk output files for background shell commands (WS6).

  Every background task started with a session id mirrors its merged
  stdout/stderr stream to `<tmp>/osa/<session>/tasks/<task-id>.out` so:

    * the model can read the FULL output with the read tool (the in-memory
      buffer is head-truncated at 512 KiB);
    * the `<task-notification>` XML can point at a durable output-file;
    * a TUI detail view can tail it without holding it all in memory.

  Writes are plain appends; a per-file byte cap stops a runaway command from
  filling the disk — once the cap is reached a single truncation marker is
  written and further chunks are dropped (CC diskOutput parity, simplified).

  ## Retention (why these files are bounded)

  The byte cap bounds one file. Nothing used to bound the *number* of files: a
  long-running session that shelled out all day left one `.out` behind per task,
  forever, and nothing in the shell subsystem ever removed one. Three things
  bound them now, in order of when they fire:

    * **`delete/2` on task retirement.** `BackgroundTask` already keeps a
      completed task pollable for `retain_ms` (1 h) and then stops itself; that
      `:retire` step now deletes the file too. Deleting on *completion* would
      race the consumer — the `<task-notification>` advertises this exact path
      and the model reads it after the fact — so the delete deliberately rides
      the existing retention timer rather than the exit.

    * **`sweep_session/2` on task start.** Enforces a per-session cap
      (`@max_files_per_session`, 200) by evicting oldest-first. This is the real
      bound: it is enforced on *growth*, so a session that starts thousands of
      tasks can never accumulate more than the cap, whatever happens to the
      retirement timers. Files touched within `@min_evict_age_ms` are never
      evicted, so a live writer is never pulled out from under itself.

    * **`sweep_orphans/1` at boot.** Removes `.out` files left behind by a
      previous daemon (crash, SIGKILL, retirement timers that never fired) and
      prunes the emptied directories. It only touches files older than the
      retention window, because a second OSA instance may be running on the same
      machine and writing into its own session dir right now.
  """
  require Logger

  # 5 GB per-file cap (CC diskOutput parity).
  @max_file_bytes 5 * 1024 * 1024 * 1024
  @truncation_marker "\n[... output truncated: file cap reached ...]\n"

  # Per-session file-count cap, enforced oldest-first when a task starts.
  @max_files_per_session 200
  # Never evict/sweep a file this fresh — it may still have a live writer, and
  # its consumer (the model reading the advertised <output-file>) may not have
  # got to it yet.
  @min_evict_age_ms 60_000
  # Boot sweep window. Matches BackgroundTask's 1 h `retain_ms`, so a boot sweep
  # removes exactly what a live retirement timer would have.
  @orphan_max_age_ms 3_600_000

  @doc "Absolute path of the output file for `{session_id, task_id}`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(session_id, task_id) when is_binary(session_id) and is_binary(task_id) do
    Path.join([base_dir(session_id), "tasks", sanitize(task_id) <> ".out"])
  end

  @doc """
  Create the task's output file (and its parent dirs) EMPTY, right when the
  task starts.

  Without this the file only came into existence on the first output chunk, so
  a background command that prints nothing — or that has not printed yet —
  advertised an `<output-file>` path that did not exist. The model then read
  it and got `No such file or directory`, which is strictly worse than no
  notification at all.

  Idempotent: an existing file is left untouched (never truncated), so this is
  safe to call on a re-init or an adopt hand-off. Always returns `:ok`.
  """
  @spec ensure(String.t() | nil, String.t()) :: :ok
  def ensure(nil, _task_id), do: :ok

  def ensure(session_id, task_id) when is_binary(session_id) and is_binary(task_id) do
    file = path(session_id, task_id)
    File.mkdir_p!(Path.dirname(file))

    unless File.exists?(file) do
      _ = File.write(file, "", [:append])
    end

    :ok
  rescue
    e ->
      Logger.debug("[task-output] ensure failed for #{task_id}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Append a chunk to the task's output file, creating parent dirs on first
  write. Always returns `:ok` — persistence is best-effort and must never
  crash the task worker.
  """
  @spec append(String.t() | nil, String.t(), binary()) :: :ok
  def append(nil, _task_id, _data), do: :ok
  def append(_sid, _task_id, data) when not is_binary(data), do: :ok

  def append(session_id, task_id, data) do
    file = path(session_id, task_id)
    File.mkdir_p!(Path.dirname(file))

    case File.stat(file) do
      {:ok, %{size: size}} when size >= @max_file_bytes ->
        :ok

      {:ok, %{size: size}} when size + byte_size(data) > @max_file_bytes ->
        _ = File.write(file, @truncation_marker, [:append])
        :ok

      _ ->
        _ = File.write(file, data, [:append])
        :ok
    end
  rescue
    e ->
      Logger.debug("[task-output] append failed for #{task_id}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Delete a single task's output file, called from `BackgroundTask`'s `:retire`
  step — i.e. only after the completed task's retention window has elapsed and
  every consumer (notification reader, `bash_output` poll, TUI tail) has had its
  chance. Never deletes on completion, which would race those readers.

  Also prunes the session's `tasks/` dir and the session dir when they become
  empty, so an idle machine does not keep a tree of empty directories. Always
  returns `:ok`.
  """
  @spec delete(String.t() | nil, String.t()) :: :ok
  def delete(nil, _task_id), do: :ok

  def delete(session_id, task_id) when is_binary(session_id) and is_binary(task_id) do
    file = path(session_id, task_id)
    _ = File.rm(file)
    prune_empty_dirs(Path.dirname(file))
    :ok
  rescue
    e ->
      Logger.debug("[task-output] delete failed for #{task_id}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Enforce the per-session file-count cap, evicting oldest-first.

  Called when a task STARTS, so the bound holds on growth rather than depending
  on retirement timers that a crash or a `:brutal_kill` shutdown can skip. Files
  modified within `#{@min_evict_age_ms}ms` are never evicted — a live writer or
  a just-advertised output file must not be pulled out from under its consumer.

  Returns the number of files removed.
  """
  @spec sweep_session(String.t() | nil, keyword()) :: non_neg_integer()
  def sweep_session(session_id, opts \\ [])
  def sweep_session(nil, _opts), do: 0

  def sweep_session(session_id, opts) when is_binary(session_id) do
    max_files = Keyword.get(opts, :max_files, @max_files_per_session)
    min_age_ms = Keyword.get(opts, :min_age_ms, @min_evict_age_ms)
    dir = Path.join(base_dir(session_id), "tasks")
    now = System.system_time(:millisecond)

    entries = stat_outputs(dir)

    evictable =
      entries
      |> Enum.filter(fn {_p, mtime} -> now - mtime >= min_age_ms end)
      |> Enum.sort_by(fn {_p, mtime} -> mtime end)

    excess = length(entries) - max_files

    if excess > 0 do
      removed =
        evictable
        |> Enum.take(excess)
        |> Enum.count(fn {p, _} -> File.rm(p) == :ok end)

      if removed > 0 do
        Logger.debug(
          "[task-output] evicted #{removed} old output file(s) for session #{session_id} " <>
            "(cap #{max_files})"
        )
      end

      removed
    else
      0
    end
  rescue
    _ -> 0
  end

  @doc """
  Boot-time sweep of orphaned task output across ALL session dirs under
  `<tmp>/osa/`.

  These are files a previous daemon left behind — killed before its retirement
  timers fired, or crashed outright. Only files older than `:older_than_ms`
  (default the same 1 h as `BackgroundTask`'s retention) are removed, because a
  second OSA instance may be running on this machine right now and actively
  writing into its own session dir; anything it owns will be young. Emptied
  `tasks/` and session dirs are pruned.

  Returns `{:ok, removed_count}`. Best-effort — never raises.
  """
  @spec sweep_orphans(keyword()) :: {:ok, non_neg_integer()}
  def sweep_orphans(opts \\ []) do
    older_than_ms = Keyword.get(opts, :older_than_ms, @orphan_max_age_ms)
    root = Keyword.get(opts, :root, Path.join(System.tmp_dir!(), "osa"))
    now = System.system_time(:millisecond)

    removed =
      case File.ls(root) do
        {:ok, session_dirs} ->
          Enum.reduce(session_dirs, 0, fn sd, acc ->
            tasks_dir = Path.join([root, sd, "tasks"])

            n =
              tasks_dir
              |> stat_outputs()
              |> Enum.filter(fn {_p, mtime} -> now - mtime >= older_than_ms end)
              |> Enum.count(fn {p, _} -> File.rm(p) == :ok end)

            prune_empty_dirs(tasks_dir)
            acc + n
          end)

        {:error, _} ->
          0
      end

    if removed > 0 do
      Logger.info("[task-output] boot sweep removed #{removed} orphaned task output file(s)")
    end

    {:ok, removed}
  rescue
    e ->
      Logger.debug("[task-output] boot sweep failed: #{Exception.message(e)}")
      {:ok, 0}
  end

  # ── Private ──────────────────────────────────────────────────────────

  # [{abs_path, mtime_ms}] for every *.out in `dir` (empty list when missing).
  defp stat_outputs(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".out"))
        |> Enum.flat_map(fn f ->
          p = Path.join(dir, f)

          case File.stat(p, time: :posix) do
            {:ok, %{mtime: mtime}} -> [{p, mtime * 1000}]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Remove `tasks/` and its session parent once they hold nothing. `File.rmdir`
  # only succeeds on an empty dir, so this can never delete live state.
  defp prune_empty_dirs(tasks_dir) do
    _ = File.rmdir(tasks_dir)
    _ = File.rmdir(Path.dirname(tasks_dir))
    :ok
  rescue
    _ -> :ok
  end

  defp base_dir(session_id),
    do: Path.join([System.tmp_dir!(), "osa", sanitize(session_id)])

  # Ids are internally generated, but never trust them as path segments —
  # strip separators, then collapse any remaining dot-dot traversal.
  defp sanitize(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.replace("..", "_")
  end
end
