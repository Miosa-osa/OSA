defmodule OptimalSystemAgent.FSCheckpoint.Config do
  @moduledoc "Configuration constants for the FSCheckpoint subsystem."

  @destructive_tools ~w(file_write file_edit multi_file_edit)
  @shell_destructive_patterns ~w(rm mv cp sed awk)
  @max_file_size 1_048_576
  @default_max_checkpoints 100

  def destructive_tools, do: @destructive_tools
  def shell_destructive_patterns, do: @shell_destructive_patterns
  def max_file_size, do: @max_file_size

  def max_checkpoints,
    do: OptimalSystemAgent.Settings.get("fs_checkpoints_max_count", @default_max_checkpoints)

  def enabled?, do: OptimalSystemAgent.Settings.get("fs_checkpoints_enabled", true)
  def repo_path, do: Path.expand("~/.osa/fs_checkpoints")
end
