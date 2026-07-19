defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.Constants do
  @moduledoc """
  Exported constants for cross-tool references.

  Other prompts that reference the task_wait tool name should use `safe_ref/3`
  against this module so a rename propagates automatically.
  """

  @tool_name "task_wait"
  def tool_name, do: @tool_name
end
