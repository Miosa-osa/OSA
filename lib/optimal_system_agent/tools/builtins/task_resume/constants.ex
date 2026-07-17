defmodule OptimalSystemAgent.Tools.Builtins.TaskResume.Constants do
  @moduledoc """
  Exported constants for cross-tool references.

  Other prompts that reference the task_resume tool name should use
  `safe_ref/3` against this module so a rename propagates automatically.
  """

  @tool_name "task_resume"
  def tool_name, do: @tool_name
end
