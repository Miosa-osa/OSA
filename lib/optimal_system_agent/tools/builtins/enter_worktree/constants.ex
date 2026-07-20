defmodule OptimalSystemAgent.Tools.Builtins.EnterWorktree.Constants do
  @moduledoc "Exported constants for the enter_worktree tool."

  alias OptimalSystemAgent.ConfigFile

  @tool_name "enter_worktree"
  def tool_name, do: @tool_name

  # Runtime-resolved so a prebuilt release uses the END USER's home, not the CI
  # runner's baked-in path. Resolved on every call via ConfigFile.config_dir/0.
  def worktrees_dir, do: Path.join(ConfigFile.config_dir(), "worktrees")
end
