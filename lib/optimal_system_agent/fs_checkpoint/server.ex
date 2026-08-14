defmodule OptimalSystemAgent.FSCheckpoint.Server do
  @moduledoc """
  GenServer that manages the shadow git repo used for filesystem checkpoints.

  The shadow repo lives at `~/.osa/fs_checkpoints/`. Before any destructive
  file operation the pre_tool_use hook calls `snapshot/3`, which copies the
  affected files into the shadow repo and creates a git commit. The commit
  message encodes the tool name, session id, and affected paths so they can
  be displayed in `list_checkpoints/1` without extra parsing.

  Restore works by re-copying files from the shadow commit back to their
  original absolute paths. It does NOT use `git checkout` against the working
  tree to avoid any accidental interaction with the host project's git history.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.FSCheckpoint.Config

  # ── Client API ────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Snapshot `paths` as they are RIGHT NOW, and do not return until the copy is
  on disk.

  ## Why this is a call and not a cast

  This ran as `GenServer.cast/2`. The pre-tool-use hook therefore returned
  immediately, the tool wrote the file, and the copy happened whenever the
  server got round to it — queued behind the previous snapshot's git
  subprocesses. Under back-to-back edits the copy ran *after* the write it was
  supposed to precede, so the checkpoint captured POST-edit content: `/rollback`
  then restored the file to the state it was already in, and reported success.
  A checkpoint that silently records the wrong bytes is worse than no
  checkpoint, because the operator stops keeping their own backup.

  The snapshot is now synchronous. The caller pays for the copy (and the git
  commit) before its write proceeds, which is exactly the ordering the feature
  claims.

  Returns `{:ok, report}` where `report` carries `:copied` and `:skipped`, or
  `{:error, reason}`. Never raises and never blocks forever: a dead or wedged
  server degrades to `{:error, _}` so a checkpoint failure can never stop the
  edit itself.
  """
  @spec snapshot(String.t(), String.t(), [String.t()]) ::
          {:ok, %{copied: [String.t()], skipped: [{String.t(), String.t()}]}}
          | {:error, String.t()}
  def snapshot(session_id, tool_name, paths) when is_list(paths) do
    if Config.enabled?() do
      GenServer.call(__MODULE__, {:snapshot, session_id, tool_name, paths}, 30_000)
    else
      {:ok, %{copied: [], skipped: []}}
    end
  catch
    :exit, _ -> {:error, "FSCheckpoint server unavailable"}
  end

  @spec list_checkpoints(pos_integer()) :: {:ok, [map()]} | {:error, String.t()}
  def list_checkpoints(limit \\ 20) do
    GenServer.call(__MODULE__, {:list, limit})
  end

  @spec restore(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def restore(checkpoint_id) do
    GenServer.call(__MODULE__, {:restore, checkpoint_id}, 30_000)
  end

  @spec diff(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(checkpoint_id) do
    GenServer.call(__MODULE__, {:diff, checkpoint_id})
  end

  @doc """
  Return the current HEAD commit hash of the shadow repo, or nil when the
  server is not running / has no commits. Used by the /rewind subsystem to
  pin the code state that existed when a rewind checkpoint was created.

  ## Why this is a table read and not a call

  This sits on the pre-request critical path: `Agent.Loop` takes a rewind
  checkpoint before every prompt, and the checkpoint pins the shadow-repo HEAD.
  It used to be `GenServer.call(__MODULE__, :head)` — a 5-second call into a
  handler that shells out to `git rev-parse`. Two costs, and the second is the
  one that bites:

    1. a process spawn + `git` exec, on every prompt; and
    2. **queueing**. The same mailbox serves `:snapshot`, which runs `git add`
       + `git commit` across a working tree. A prompt submitted while a
       snapshot is in flight waits for the whole commit, and on a large tree
       that is where a 5-second timeout stops being theoretical.

  HEAD only changes when THIS server changes it — nothing else writes to the
  shadow repo — so the server publishes it into an ETS table on every mutation
  and readers take it from there, lock-free and never queued. The call is kept
  as a cold-start fallback for the one read that can precede any publish.
  """
  @spec head() :: String.t() | nil
  def head do
    case cached_head(Config.repo_path()) do
      {:ok, hash} ->
        hash

      :miss ->
        GenServer.call(__MODULE__, :head)
    end
  catch
    :exit, _ -> nil
  end

  # ── HEAD cache ────────────────────────────────────────────────────────

  @head_table :osa_fs_checkpoint_head

  @doc false
  @spec cached_head(String.t()) :: {:ok, String.t() | nil} | :miss
  def cached_head(repo_path) do
    case :ets.whereis(@head_table) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(@head_table, repo_path) do
          [{^repo_path, hash}] -> {:ok, hash}
          _ -> :miss
        end
    end
  end

  defp ensure_head_table do
    case :ets.whereis(@head_table) do
      :undefined ->
        :ets.new(@head_table, [:named_table, :public, :set, read_concurrency: true])

      tid ->
        tid
    end
  end

  # Publish the repo's current HEAD so `head/0` never has to ask. Called after
  # every operation that can move it, and once at init.
  defp publish_head(repo_path) do
    ensure_head_table()
    :ets.insert(@head_table, {repo_path, do_head(repo_path)})
    :ok
  end

  @doc """
  Restore the full working tree to the snapshotted state as of `commit`.

  Every file present in that commit's tree is written back to its original
  absolute path with the content it had at `commit`. Files created after the
  commit are left untouched (this never deletes). Used by /rewind code restore.
  """
  @spec restore_to(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def restore_to(commit) when is_binary(commit) do
    GenServer.call(__MODULE__, {:restore_to, commit}, 30_000)
  catch
    :exit, _ -> {:error, "FSCheckpoint server unavailable"}
  end

  @doc """
  Compute an additions/deletions/files-changed summary between two shadow-repo
  commits, mirroring opencode `snapshot.diff` used by `/rewind` diff summaries.

  `from_commit` and `to_commit` default `to_commit` to the shadow repo's
  current `HEAD`. Binary files are counted toward `files` but contribute 0 to
  `additions`/`deletions` (git reports `-`/`-` for them in `--numstat`).
  """
  @spec diff_stat(String.t() | nil, String.t()) ::
          {:ok,
           %{additions: integer(), deletions: integer(), files: integer(), paths: [String.t()]}}
          | {:error, String.t()}
  def diff_stat(from_commit, to_commit \\ "HEAD")

  def diff_stat(nil, _to_commit), do: {:error, "no code snapshot to diff from"}

  def diff_stat(from_commit, to_commit) when is_binary(from_commit) do
    GenServer.call(__MODULE__, {:diff_stat, from_commit, to_commit})
  catch
    :exit, _ -> {:error, "FSCheckpoint server unavailable"}
  end

  # ── Server callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Self-register the pre_tool_use hook so the server owns its own wiring.
    # This avoids touching hooks.ex and keeps the feature fully self-contained.
    OptimalSystemAgent.Agent.Hooks.register(
      :pre_tool_use,
      "fs_checkpoint",
      &OptimalSystemAgent.FSCheckpoint.Hook.pre_tool_use/1,
      priority: 11
    )

    repo = Config.repo_path()

    # An OPTIONAL feature must not be able to take down the application.
    #
    # `ensure_shadow_repo/1` shells out to git. In a container without git
    # installed that raises `:enoent`, and because this runs in `init/1` the
    # failure propagated through Supervisors.Extensions and killed OSA at boot
    # — a filesystem-checkpoint convenience taking the whole agent with it.
    # Found by running OSA inside a Terminal-Bench task image.
    #
    # Degrading is the correct behaviour: checkpoints are unavailable, and
    # everything else works. The warning names the cause so it is obvious what
    # to install, rather than leaving a silently missing feature.
    case start_checkpoints(repo) do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning(
          "[fs_checkpoint] disabled — #{reason}. " <>
            "File checkpoints and /rewind are unavailable this session; " <>
            "install git to enable them."
        )

        {:ok, %{disabled: true}}
    end
  end

  defp start_checkpoints(repo) do
    ensure_shadow_repo(repo)
    publish_head(repo)
    :ok
  rescue
    e in ErlangError ->
      case e do
        %ErlangError{original: :enoent} -> {:error, "git is not installed"}
        other -> {:error, Exception.message(other)}
      end

    e ->
      {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "git failed: #{inspect(reason)}"}
  end

  @impl true
  def handle_call({:snapshot, session_id, tool_name, paths}, _from, state) do
    path = repo_path()

    result =
      try do
        do_snapshot(path, session_id, tool_name, paths)
      rescue
        e ->
          Logger.warning("[fs_checkpoint] Snapshot failed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    # A snapshot commits, so HEAD moved. Republish before replying, while the
    # mailbox is still ours — readers must never see a stale hash.
    publish_head(path)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list, limit}, _from, state) do
    result = do_list(repo_path(), limit)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:restore, checkpoint_id}, _from, state) do
    path = repo_path()
    result = do_restore(path, checkpoint_id)
    publish_head(path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:diff, checkpoint_id}, _from, state) do
    result = do_diff(repo_path(), checkpoint_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:head, _from, state) do
    # Cold-start fallback only — `head/0` reads the published table first. Take
    # the opportunity to publish, so this path is taken at most once per repo.
    path = repo_path()
    publish_head(path)
    {:reply, do_head(path), state}
  end

  @impl true
  def handle_call({:restore_to, commit}, _from, state) do
    path = repo_path()
    result = do_restore_to(path, commit)
    publish_head(path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:diff_stat, from_commit, to_commit}, _from, state) do
    result = do_diff_stat(repo_path(), from_commit, to_commit)
    {:reply, result, state}
  end

  # ── Private: repo management ──────────────────────────────────────────

  # Read per call rather than frozen into the GenServer's state at init, so the
  # location is a configuration value rather than a property of one process
  # instance. Tests point it at a temp directory; without that, exercising the
  # checkpoint subsystem at all meant committing into the operator's real
  # ~/.osa/fs_checkpoints history.
  defp repo_path, do: Config.repo_path()

  defp ensure_shadow_repo(repo_path) do
    File.mkdir_p!(repo_path)
    git_dir = Path.join(repo_path, ".git")

    unless File.dir?(git_dir) do
      {_, 0} = OptimalSystemAgent.Git.cmd(["init"], cd: repo_path, stderr_to_stdout: true)

      {_, 0} =
        OptimalSystemAgent.Git.cmd(
          [
            "-c",
            "user.name=OSA Checkpoint",
            "-c",
            "user.email=checkpoint@osa",
            "commit",
            "--allow-empty",
            "-m",
            "init"
          ],
          cd: repo_path,
          stderr_to_stdout: true
        )

      Logger.info("[fs_checkpoint] Shadow repo initialized at #{repo_path}")
    end
  end

  # ── Private: snapshot ─────────────────────────────────────────────────

  defp do_snapshot(repo_path, session_id, tool_name, paths) do
    # The path is read per call (see `repo_path/0`), so the repo may not exist
    # yet — and it may have been deleted underneath a long-running server.
    ensure_shadow_repo(repo_path)

    # Files this snapshot will NOT protect. They used to be dropped in silence
    # by two `Enum.filter/2`s while the log line counted only the survivors, so
    # a 2 MiB file looked checkpointed and was not — the operator found out at
    # `/rollback` time, which is the one moment the information is useless.
    {copyable, skipped} = Enum.split_with(paths, &snapshotable?/1)

    copied =
      Enum.map(copyable, fn original_path ->
        # Store under the absolute path structure inside the shadow repo so
        # restore can reconstruct the original location without metadata.
        dest = Path.join(repo_path, original_path)
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(original_path, dest)
        original_path
      end)

    skipped = Enum.map(skipped, fn path -> {path, skip_reason(path)} end)

    if skipped != [] do
      Logger.warning(
        "[fs_checkpoint] NOT checkpointed before #{tool_name} — /rollback cannot restore " <>
          "these: " <>
          Enum.map_join(skipped, ", ", fn {path, reason} -> "#{path} (#{reason})" end)
      )
    end

    if copied == [] do
      {:ok, %{copied: [], skipped: skipped}}
    else
      commit_snapshot(repo_path, session_id, tool_name, copied, skipped)
    end
  end

  defp commit_snapshot(repo_path, session_id, tool_name, copied, skipped) do
    {_, 0} = OptimalSystemAgent.Git.cmd(["add", "-A"], cd: repo_path, stderr_to_stdout: true)

    commit_msg = "#{tool_name} | #{session_id} | #{Enum.join(copied, ", ")}"

    # The exit status used to be bound as `{_, _}` and thrown away, and the
    # success line below was logged unconditionally — so a failed commit (repo
    # locked by a concurrent git, bad ownership, disk full) was indistinguishable
    # from a good one. The files are copied into the worktree either way, but
    # without a commit there is no checkpoint to restore FROM. `git add` two
    # lines up already asserted `{_, 0}`; this one now does too.
    # The shadow repo is OSA's own, but the *files copied into it* are the
    # user's — including any `.gitattributes` a tool just wrote. Going through
    # the hardened wrapper keeps a checkpointed attributes file from selecting
    # a filter driver during `commit`, and keeps hooks off a repo that should
    # never have any.
    case OptimalSystemAgent.Git.cmd(
           [
             "-c",
             "user.name=OSA Checkpoint",
             "-c",
             "user.email=checkpoint@osa",
             "commit",
             "-m",
             commit_msg
           ],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        maybe_prune(repo_path)
        Logger.debug("[fs_checkpoint] Snapshot: #{length(copied)} file(s) for #{tool_name}")
        {:ok, %{copied: copied, skipped: skipped}}

      {output, status} ->
        Logger.warning(
          "[fs_checkpoint] Snapshot commit FAILED (exit #{status}) for #{tool_name} — " <>
            "#{length(copied)} file(s) are NOT recoverable via /rollback: #{String.trim(output)}"
        )

        {:error, "checkpoint commit failed (exit #{status}): #{String.trim(output)}"}
    end
  end

  defp snapshotable?(path) do
    File.regular?(path) and file_size(path) <= Config.max_file_size()
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> :infinity
    end
  end

  defp skip_reason(path) do
    cond do
      not File.exists?(path) -> "does not exist"
      not File.regular?(path) -> "not a regular file"
      file_size(path) == :infinity -> "cannot stat"
      true -> "#{file_size(path)} bytes exceeds the #{Config.max_file_size()}-byte limit"
    end
  end

  # ── Private: list ─────────────────────────────────────────────────────

  defp do_list(repo_path, limit) do
    case OptimalSystemAgent.Git.cmd(["log", "--format=%H|%s|%ci", "-#{limit}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        entries =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.ends_with?(&1, "|init|"))
          |> Enum.reject(fn line ->
            case String.split(line, "|", parts: 3) do
              [_, "init", _] -> true
              _ -> false
            end
          end)
          |> Enum.map(&parse_log_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {err, _} ->
        {:error, "Failed to list checkpoints: #{err}"}
    end
  end

  defp parse_log_line(line) do
    case String.split(line, "|", parts: 3) do
      [hash, subject, date] ->
        parts = String.split(subject, " | ", parts: 3)

        %{
          id: String.slice(hash, 0, 8),
          full_id: hash,
          tool: List.first(parts) || subject,
          files: List.last(parts) || "",
          date: String.trim(date)
        }

      _ ->
        nil
    end
  end

  # ── Private: restore ──────────────────────────────────────────────────

  defp do_restore(repo_path, checkpoint_id) do
    case OptimalSystemAgent.Git.cmd(["rev-parse", checkpoint_id],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {full_hash, 0} ->
        full_hash = String.trim(full_hash)
        restore_files_from_commit(repo_path, full_hash)

      {_, _} ->
        {:error, "Checkpoint '#{checkpoint_id}' not found"}
    end
  end

  defp restore_files_from_commit(repo_path, full_hash) do
    case OptimalSystemAgent.Git.cmd(
           ["diff-tree", "--no-commit-id", "-r", "-z", "--name-only", full_hash],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {files_output, 0} ->
        restored =
          files_output
          |> split_z()
          |> Enum.map(fn file_in_repo ->
            source = Path.join(repo_path, file_in_repo)
            # file_in_repo is the absolute path stored without leading slash
            target = "/" <> file_in_repo

            if File.regular?(source) do
              File.mkdir_p!(Path.dirname(target))
              File.cp!(source, target)
              target
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, "Restored #{length(restored)} file(s): #{Enum.join(restored, ", ")}"}

      {err, _} ->
        {:error, "Failed to read checkpoint files: #{err}"}
    end
  end

  # Git's default pathname output is *quoted*: a path containing a non-ASCII
  # byte, a quote, a backslash or a control character comes back as
  # `"caf\303\251.ex"` — with the surrounding quotes and the octal escapes as
  # literal characters. Splitting that on "\n" and prefixing "/" produced a
  # restore destination that does not exist, so the file was silently not
  # restored (or, with `File.mkdir_p!`, a junk directory was created). A
  # filename containing a newline broke the framing outright and could aim a
  # restore at an unrelated path.
  #
  # `-z` turns both problems off at the source: NUL-separated, never quoted,
  # never escaped.
  defp split_z(output), do: String.split(output, <<0>>, trim: true)

  # ── Private: head / restore_to (whole-tree, for /rewind) ─────────────

  defp do_head(repo_path) do
    case OptimalSystemAgent.Git.cmd(["rev-parse", "HEAD"], cd: repo_path, stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp do_restore_to(repo_path, commit) do
    case OptimalSystemAgent.Git.cmd(["rev-parse", commit], cd: repo_path, stderr_to_stdout: true) do
      {full_hash, 0} ->
        full_hash = String.trim(full_hash)
        restore_tree_from_commit(repo_path, full_hash)

      {_, _} ->
        {:error, "Commit '#{commit}' not found in shadow repo"}
    end
  end

  defp restore_tree_from_commit(repo_path, full_hash) do
    case OptimalSystemAgent.Git.cmd(["ls-tree", "-r", "-z", "--name-only", full_hash],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {files_output, 0} ->
        restored =
          files_output
          |> split_z()
          |> Enum.map(fn file_in_repo ->
            target = "/" <> file_in_repo

            # NO `stderr_to_stdout` here. This output is not a status message —
            # it is the bytes that get written into the user's file two lines
            # down. Merging stderr in meant any warning git felt like emitting
            # ("warning: LF will be replaced by CRLF", advice, locale noise) was
            # prepended to the restored content, corrupting the very file the
            # restore existed to repair.
            case OptimalSystemAgent.Git.cmd(["show", "#{full_hash}:#{file_in_repo}"],
                   cd: repo_path
                 ) do
              {content, 0} ->
                File.mkdir_p!(Path.dirname(target))
                File.write!(target, content)
                target

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok,
         "Restored #{length(restored)} file(s) to code state at #{String.slice(full_hash, 0, 8)}"}

      {err, _} ->
        {:error, "Failed to read checkpoint tree: #{err}"}
    end
  end

  # ── Private: diff ─────────────────────────────────────────────────────

  defp do_diff(repo_path, checkpoint_id) do
    case OptimalSystemAgent.Git.cmd(["show", "--stat", "--patch", checkpoint_id],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {err, _} -> {:error, "Failed to show diff: #{err}"}
    end
  end

  # ── Private: diff_stat (numstat summary, for /rewind diff) ────────────

  defp do_diff_stat(repo_path, from_commit, to_commit) do
    with {:ok, from_hash} <- rev_parse(repo_path, from_commit),
         {:ok, to_hash} <- rev_parse(repo_path, to_commit) do
      case OptimalSystemAgent.Git.cmd(["diff", "--numstat", from_hash, to_hash],
             cd: repo_path,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          {additions, deletions, paths} =
            output
            |> String.trim()
            |> String.split("\n", trim: true)
            |> Enum.reduce({0, 0, []}, fn line, {add_acc, del_acc, paths_acc} ->
              case String.split(line, "\t", parts: 3) do
                [add, del, path] ->
                  {add_acc + numstat_int(add), del_acc + numstat_int(del), [path | paths_acc]}

                _ ->
                  {add_acc, del_acc, paths_acc}
              end
            end)

          paths = Enum.reverse(paths)
          {:ok, %{additions: additions, deletions: deletions, files: length(paths), paths: paths}}

        {err, _} ->
          {:error, "Failed to diff checkpoints: #{err}"}
      end
    end
  end

  defp rev_parse(repo_path, commit) do
    case OptimalSystemAgent.Git.cmd(["rev-parse", commit], cd: repo_path, stderr_to_stdout: true) do
      {hash, 0} -> {:ok, String.trim(hash)}
      {_, _} -> {:error, "Commit '#{commit}' not found in shadow repo"}
    end
  end

  # git --numstat reports "-" for binary files; count the file but not lines.
  defp numstat_int("-"), do: 0

  defp numstat_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  # ── Private: pruning ──────────────────────────────────────────────────

  defp maybe_prune(repo_path) do
    max = Config.max_checkpoints()

    case OptimalSystemAgent.Git.cmd(["rev-list", "--count", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {count_str, 0} ->
        count = count_str |> String.trim() |> String.to_integer()

        if count > max + 10 do
          Logger.info(
            "[fs_checkpoint] Checkpoint count #{count} exceeds max #{max} — consider pruning the shadow repo at #{repo_path}"
          )
        end

      _ ->
        :ok
    end
  end
end
