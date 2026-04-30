defmodule OptimalSystemAgent.Tools.Builtins.Rollback.Prompt do
  @moduledoc "Dynamic prompt for the rollback tool."

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    "List, inspect, or restore filesystem checkpoints created before destructive operations. " <>
      "Use action 'list' to see recent checkpoints, 'diff' to preview what changed, " <>
      "or 'restore' to revert files to their pre-modification state."
  end
end
