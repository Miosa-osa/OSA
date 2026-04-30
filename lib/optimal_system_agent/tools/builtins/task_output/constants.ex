defmodule OptimalSystemAgent.Tools.Builtins.TaskOutput.Constants do
  @moduledoc """
  Exported constants for cross-tool references.

  Other prompts that reference the task_output tool name should use
  `safe_ref/3` against this module so a rename propagates automatically.
  """

  @tool_name "task_output"
  def tool_name, do: @tool_name
end
