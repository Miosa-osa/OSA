defmodule OptimalSystemAgent.FSCheckpoint.Config do
  @moduledoc "Configuration constants for the FSCheckpoint subsystem."

  @destructive_tools ~w(file_write file_edit multi_file_edit notebook_edit)

  # Matched against the BASENAME of each word in the command, not as a
  # substring of the whole string — see `FSCheckpoint.Hook.destructive?/1`.
  @shell_destructive_patterns ~w(rm mv cp sed awk truncate dd shred)
  @max_file_size 1_048_576
  @default_max_checkpoints 100

  def destructive_tools, do: @destructive_tools
  def shell_destructive_patterns, do: @shell_destructive_patterns
  def max_file_size, do: @max_file_size

  def max_checkpoints,
    do: OptimalSystemAgent.Settings.get("fs_checkpoints_max_count", @default_max_checkpoints)

  def enabled?, do: OptimalSystemAgent.Settings.get("fs_checkpoints_enabled", true)

  @doc """
  Where the shadow git repo lives.

  Overridable through application env so a test can point the subsystem at a
  temp directory instead of committing into the operator's real checkpoint
  history — without which none of this is testable at all.
  """
  def repo_path do
    case Application.get_env(:optimal_system_agent, :fs_checkpoint_repo_path) do
      path when is_binary(path) -> Path.expand(path)
      _ -> Path.expand("~/.osa/fs_checkpoints")
    end
  end
end
