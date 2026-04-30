defmodule OptimalSystemAgent.Agent.Worktree do
  @moduledoc """
  Git worktree isolation for parallel agent execution.

  Creates temporary git worktrees so agents can operate on isolated copies
  of the repository without file conflicts. On completion, changes can be
  merged back or the worktree is cleaned up.

  Flow:
    1. `create/1` — creates a worktree branch + directory
    2. Agent runs with CWD set to the worktree path
    3. `cleanup/2` — either merges changes back or removes the worktree

  The worktree directory lives under `~/.osa/worktrees/<agent_id>/`.
  """
  require Logger

  @worktrees_dir Path.expand("~/.osa/worktrees")

  @doc """
  Create an isolated git worktree for an agent.

  Returns `{:ok, %{path: worktree_path, branch: branch_name}}` or `{:error, reason}`.
  """
  def create(agent_id, opts \\ []) do
    base_dir = Keyword.get(opts, :repo_dir, File.cwd!())
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, agent_id, "_")
    branch_name = "osa-worktree-#{safe_id}-#{System.unique_integer([:positive])}"
    worktree_path = Path.join(@worktrees_dir, safe_id)

    # Ensure clean state — remove any stale worktree at this path
    cleanup_stale(worktree_path, base_dir)
    File.mkdir_p!(@worktrees_dir)

    # Create the worktree with a new branch from HEAD
    case System.cmd("git", ["worktree", "add", "-b", branch_name, worktree_path],
           cd: base_dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("[worktree] Created #{worktree_path} on branch #{branch_name}")

        # Emit hook event
        try do
          OptimalSystemAgent.Agent.Hooks.run_async(:worktree_create, %{
            agent_id: agent_id,
            path: worktree_path,
            branch: branch_name
          })
        rescue
          _ -> :ok
        end

        {:ok, %{path: worktree_path, branch: branch_name}}

      {output, _code} ->
        Logger.warning("[worktree] Failed to create: #{output}")
        {:error, "Git worktree creation failed: #{String.trim(output)}"}
    end
  rescue
    e ->
      Logger.error("[worktree] Exception: #{Exception.message(e)}")
      {:error, "Worktree error: #{Exception.message(e)}"}
  end

  @doc """
  Clean up a worktree after agent completion.

  If `merge: true`, attempts to merge the worktree branch back to the original branch.
  Otherwise, dirty worktrees are preserved by default for parent review. Pass
  `discard: true` to remove a dirty worktree without merging.

  Returns `:ok` or `{:error, reason}`.
  """
  def cleanup(worktree_path, opts \\ []) do
    merge = Keyword.get(opts, :merge, false)
    discard = Keyword.get(opts, :discard, false)
    base_dir = Keyword.get(opts, :repo_dir, File.cwd!())

    # Check if the worktree has any changes
    has_changes = worktree_has_changes?(worktree_path)

    result =
      cond do
        merge and has_changes ->
          with :ok <- merge_worktree(worktree_path, base_dir) do
            remove_worktree(worktree_path, base_dir)
          end

        has_changes and not discard ->
          Logger.info("[worktree] Preserving dirty worktree #{worktree_path} for review")
          :ok

        true ->
          remove_worktree(worktree_path, base_dir)
      end

    # Emit hook event
    try do
      OptimalSystemAgent.Agent.Hooks.run_async(:worktree_remove, %{
        path: worktree_path,
        had_changes: has_changes,
        merged: merge and has_changes,
        preserved: has_changes and not merge and not discard
      })
    rescue
      _ -> :ok
    end

    result
  end

  @doc "Check if a path is inside a worktree."
  def worktree?(path) do
    String.starts_with?(Path.expand(path), @worktrees_dir)
  end

  @doc "List all active worktrees."
  def list do
    case File.ls(@worktrees_dir) do
      {:ok, dirs} ->
        Enum.map(dirs, fn dir ->
          path = Path.join(@worktrees_dir, dir)
          branch = get_worktree_branch(path)
          %{path: path, name: dir, branch: branch}
        end)

      {:error, _} ->
        []
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp worktree_has_changes?(path) do
    case System.cmd("git", ["status", "--porcelain"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  defp merge_worktree(worktree_path, base_dir) do
    # Get the branch name from the worktree
    branch = get_worktree_branch(worktree_path)

    if branch do
      # Commit any uncommitted changes in the worktree
      System.cmd("git", ["add", "-A"], cd: worktree_path, stderr_to_stdout: true)

      System.cmd("git", ["commit", "-m", "Agent worktree changes"],
        cd: worktree_path,
        stderr_to_stdout: true
      )

      # Merge the branch back
      case System.cmd("git", ["merge", "--no-ff", branch, "-m", "Merge agent worktree #{branch}"],
             cd: base_dir,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          Logger.info("[worktree] Merged branch #{branch} back to main")
          :ok

        {output, _code} ->
          Logger.warning("[worktree] Merge failed: #{output}")

          {:error,
           "Merge failed: #{String.trim(output)}. Branch #{branch} preserved for manual merge."}
      end
    else
      {:error, "Could not determine worktree branch"}
    end
  end

  defp remove_worktree(worktree_path, base_dir) do
    branch = get_worktree_branch(worktree_path)

    # Remove the worktree
    System.cmd("git", ["worktree", "remove", "--force", worktree_path],
      cd: base_dir,
      stderr_to_stdout: true
    )

    # Delete the branch (if it exists and wasn't merged)
    if branch do
      System.cmd("git", ["branch", "-D", branch], cd: base_dir, stderr_to_stdout: true)
    end

    # Clean up the directory if it still exists
    File.rm_rf(worktree_path)

    Logger.debug("[worktree] Removed #{worktree_path}")
    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_stale(worktree_path, base_dir) do
    if File.exists?(worktree_path) do
      Logger.debug("[worktree] Cleaning up stale worktree at #{worktree_path}")
      remove_worktree(worktree_path, base_dir)
    end
  end

  defp get_worktree_branch(path) do
    case System.cmd("git", ["branch", "--show-current"], cd: path, stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
