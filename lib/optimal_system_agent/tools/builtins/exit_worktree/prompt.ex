defmodule OptimalSystemAgent.Tools.Builtins.ExitWorktree.Prompt do
  @moduledoc "Dynamic prompt for the exit_worktree tool."

  def render(_opts \\ []) do
    """
    Remove or finalize a git worktree created by enter_worktree.

    Call this when you are finished with the isolated worktree, either to merge
    your changes back or to discard them entirely.

    Options:
    - `path` (required) — the worktree path returned by enter_worktree.
    - `merge` (default false) — when true, stages and commits any outstanding
      changes in the worktree, then merges the worktree branch back into the
      repository's current branch via `git merge --no-ff`. The merge is
      attempted before the worktree is removed; on conflict the error is
      reported and the worktree is kept for manual resolution.
    - `keep` (default false) — when true the worktree directory is left on
      disk after the git bookkeeping is removed. Useful for post-mortem
      inspection when `merge: false`.
    - `force` (default false) — pass `--force` to `git worktree remove` when
      the worktree has uncommitted changes that you want to discard.

    Returns a summary line describing what happened.
    """
  end
end
