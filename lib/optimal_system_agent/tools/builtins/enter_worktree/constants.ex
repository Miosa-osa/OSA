defmodule OptimalSystemAgent.Tools.Builtins.EnterWorktree.Constants do
  @moduledoc "Exported constants for the enter_worktree tool."

  @tool_name "enter_worktree"
  def tool_name, do: @tool_name

  @worktrees_dir Path.expand("~/.osa/worktrees")
  def worktrees_dir, do: @worktrees_dir
end
