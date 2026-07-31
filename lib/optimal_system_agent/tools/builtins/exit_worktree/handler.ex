defmodule OptimalSystemAgent.Tools.Builtins.ExitWorktree.Handler do
  @moduledoc """
  Validation, permission checking, and execution for `exit_worktree`.

  Removes a git worktree that was created by `enter_worktree`, optionally
  merging changes back first.

  Merge flow:
    1. Stage + commit any outstanding changes inside the worktree.
    2. `git merge --no-ff <branch>` from the main repo dir.
    3. On success: remove the worktree.
    4. On conflict: return the error message and leave the worktree intact
       for manual resolution.

  Remove-only flow (merge: false):
    1. `git worktree remove [--force] <path>` — removes git bookkeeping.
    2. Unless `keep: true`, the directory is also removed with File.rm_rf/1.
    3. The worktree branch is deleted unless the merge succeeded
       (a successful merge means the branch ref is already merged in).
  """

  require Logger

  alias OptimalSystemAgent.Tools.UseContext

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"path" => path} = input, _ctx) when is_binary(path) and path != "" do
    merge = Map.get(input, "merge", false)
    keep = Map.get(input, "keep", false)
    force = Map.get(input, "force", false)

    cond do
      not is_boolean(merge) ->
        {:error, "merge must be a boolean", -32_602}

      not is_boolean(keep) ->
        {:error, "keep must be a boolean", -32_602}

      not is_boolean(force) ->
        {:error, "force must be a boolean", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"path" => _}, _ctx),
    do: {:error, "path must be a non-empty string", -32_602}

  def validate(_input, _ctx),
    do: {:error, "Missing required parameter: path", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(%{"path" => path} = input, ctx) do
    expanded = Path.expand(path)

    cond do
      not File.dir?(expanded) ->
        {:deny,
         "Worktree path does not exist or is not a directory: #{expanded}. " <>
           "Nothing to remove."}

      not worktree_path?(expanded, ctx) ->
        {:deny,
         "Path #{expanded} does not appear to be a git worktree. " <>
           "exit_worktree only removes paths created by enter_worktree."}

      true ->
        {:allow, input}
    end
  end

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(%{"path" => path} = input, ctx) do
    path = Path.expand(path)
    merge = Map.get(input, "merge", false)
    keep = Map.get(input, "keep", false)
    force = Map.get(input, "force", false)
    repo_dir = resolve_repo_dir(ctx)

    branch = get_worktree_branch(path)

    with :ok <- maybe_merge(merge, path, branch, repo_dir) do
      remove_result = remove_worktree(path, repo_dir, keep, force)
      delete_branch_if_needed(merge, branch, repo_dir)

      run_hooks_async(:worktree_remove, %{
        path: path,
        branch: branch,
        merged: merge,
        kept: keep
      })

      case remove_result do
        :ok ->
          branch_status = if branch, do: "Branch #{branch} preserved.", else: ""
          keep_note = if keep, do: " Directory left on disk at #{path}.", else: ""
          {:ok, "Worktree at #{path} removed.#{keep_note} #{branch_status}" |> String.trim()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.error("[exit_worktree] Unexpected error: #{Exception.message(e)}")
      {:error, "exit_worktree error: #{Exception.message(e)}"}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp maybe_merge(false, _path, _branch, _repo_dir), do: :ok

  defp maybe_merge(true, path, branch, repo_dir) when is_binary(branch) do
    # Stage and commit outstanding changes in the worktree first.
    OptimalSystemAgent.Git.cmd(["add", "-A"], cd: path, stderr_to_stdout: true)

    {status_out, _} =
      OptimalSystemAgent.Git.cmd(["status", "--porcelain"], cd: path, stderr_to_stdout: true)

    if String.trim(status_out) != "" do
      OptimalSystemAgent.Git.cmd(["commit", "-m", "exit_worktree: commit before merge"],
        cd: path,
        stderr_to_stdout: true
      )
    end

    case System.cmd(
           "git",
           ["merge", "--no-ff", branch, "-m", "Merge worktree branch #{branch}"],
           cd: repo_dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("[exit_worktree] Merged branch #{branch} into #{repo_dir}")
        :ok

      {output, _code} ->
        trimmed = String.trim(output)
        Logger.warning("[exit_worktree] Merge failed: #{trimmed}")

        {:error,
         "Merge failed: #{trimmed}\n" <>
           "Branch #{branch} and worktree at #{path} preserved for manual resolution."}
    end
  end

  defp maybe_merge(true, _path, nil, _repo_dir) do
    {:error, "Could not determine the worktree branch — cannot merge."}
  end

  defp remove_worktree(path, repo_dir, keep, force) do
    # When keep: true we want to preserve the directory on disk but still
    # remove the git worktree bookkeeping. `git worktree remove` always deletes
    # the directory, so when keep is requested we instead:
    #   1. Move the directory aside temporarily.
    #   2. Let git remove the (now-empty) registration path.
    #   3. Move the directory back.
    if keep do
      remove_worktree_keep_dir(path, repo_dir, force)
    else
      remove_worktree_delete_dir(path, repo_dir, force)
    end
  end

  defp remove_worktree_delete_dir(path, repo_dir, force) do
    args =
      if force,
        do: ["worktree", "remove", "--force", path],
        else: ["worktree", "remove", path]

    case OptimalSystemAgent.Git.cmd(args, cd: repo_dir, stderr_to_stdout: true) do
      {_out, 0} ->
        # git already removed the directory; ensure it is gone.
        File.rm_rf(path)
        :ok

      {output, _code} ->
        trimmed = String.trim(output)

        if trimmed =~ "has modified files" or trimmed =~ "is not empty" do
          {:error,
           "Worktree has uncommitted changes. " <>
             "Pass force: true to discard them, or merge: true to commit and merge first."}
        else
          # Best-effort cleanup even if git command returned non-zero.
          File.rm_rf(path)
          Logger.warning("[exit_worktree] git worktree remove returned: #{trimmed}")
          :ok
        end
    end
  end

  defp remove_worktree_keep_dir(path, repo_dir, force) do
    tmp_path = path <> ".osa-keep-#{System.unique_integer([:positive])}"

    case File.rename(path, tmp_path) do
      :ok ->
        args =
          if force,
            do: ["worktree", "remove", "--force", path],
            else: ["worktree", "remove", path]

        # The original path is gone — git will either succeed or prune it.
        case OptimalSystemAgent.Git.cmd(args, cd: repo_dir, stderr_to_stdout: true) do
          {_out, 0} ->
            :ok

          {output, _code} ->
            # Directory is already moved; prune stale bookkeeping.
            OptimalSystemAgent.Git.cmd(["worktree", "prune"], cd: repo_dir, stderr_to_stdout: true)
            Logger.debug("[exit_worktree] prune after keep: #{String.trim(output)}")
        end

        # Restore directory to original location regardless.
        File.rename(tmp_path, path)
        :ok

      {:error, reason} ->
        Logger.warning("[exit_worktree] keep: could not move directory: #{inspect(reason)}")
        # Fall back to normal removal (directory will be deleted).
        remove_worktree_delete_dir(path, repo_dir, force)
    end
  end

  defp delete_branch_if_needed(_merged = true, branch, repo_dir) when is_binary(branch) do
    # Branch was merged — safe to delete.
    OptimalSystemAgent.Git.cmd(["branch", "-d", branch], cd: repo_dir, stderr_to_stdout: true)
  end

  defp delete_branch_if_needed(false, branch, repo_dir) when is_binary(branch) do
    # Not merged — keep the branch in case the user wants to reuse it.
    _ = repo_dir
    Logger.debug("[exit_worktree] Branch #{branch} retained (not merged)")
  end

  defp delete_branch_if_needed(_merged, _branch, _repo_dir), do: :ok

  defp get_worktree_branch(path) do
    case OptimalSystemAgent.Git.cmd(["branch", "--show-current"], cd: path, stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A path is considered a worktree if `git worktree list` in the repo
  # mentions it, or if it is under ~/.osa/worktrees/ (our convention).
  defp worktree_path?(path, ctx) do
    repo_dir = resolve_repo_dir(ctx)

    osa_dir = Path.expand("~/.osa/worktrees")
    under_osa = String.starts_with?(path, osa_dir)

    listed =
      case OptimalSystemAgent.Git.cmd(["worktree", "list", "--porcelain"],
             cd: repo_dir,
             stderr_to_stdout: true
           ) do
        {output, 0} -> output =~ path
        _ -> false
      end

    under_osa or listed
  rescue
    _ -> false
  end

  defp resolve_repo_dir(%UseContext{extras: %{cwd: cwd}}) when is_binary(cwd), do: cwd
  defp resolve_repo_dir(_ctx), do: File.cwd!()

  defp run_hooks_async(event, payload) do
    try do
      OptimalSystemAgent.Agent.Hooks.run_async(event, payload)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
