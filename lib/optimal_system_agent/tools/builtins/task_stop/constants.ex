defmodule OptimalSystemAgent.Tools.Builtins.TaskStop.Constants do
  @moduledoc """
  Exported constants for cross-tool references.

  Other prompts that reference the task_stop tool name should use
  `safe_ref/3` against this module so a rename propagates automatically.
  """

  @tool_name "task_stop"
  def tool_name, do: @tool_name
end
