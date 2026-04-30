defmodule OptimalSystemAgent.Tools.Builtins.EnterWorktree.Prompt do
  @moduledoc "Dynamic prompt for the enter_worktree tool."

  def render(_opts \\ []) do
    """
    Isolate risky changes in a git worktree.

    Creates a new git worktree on a dedicated branch so you can make and test
    changes without touching the main working tree. Subsequent tool calls that
    operate on the filesystem should use the returned path as their working
    directory.

    Use this before applying speculative changes, running destructive scripts,
    or experimenting with refactors you may want to discard. Pair with
    `exit_worktree` to merge back or clean up when done.

    - If `branch` is omitted a timestamped name is generated automatically.
    - If `path` is omitted the worktree lands under `~/.osa/worktrees/<branch>`.
    - Calling with a path that already exists returns an error — use exit_worktree
      first to clean up the previous isolation.
    - Must be called from inside a git repository.

    Returns the absolute path of the new worktree so you can pass it to other
    tools (e.g. shell_execute with a cd, or file_read/file_write with the full
    path).
    """
  end
end
