defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite.Constants do
  @moduledoc """
  Exported constants for cross-tool references.

  Mirrors the pattern in `FileRead.Constants`. Any other module that needs
  to reference the task_write tool name gets it through here so a rename
  propagates automatically.
  """

  @tool_name "task_write"
  def tool_name, do: @tool_name

  @default_session "default"
  def default_session, do: @default_session

  # All valid action atoms for the task state machine.
  @actions ~w(add add_multiple start complete fail list clear update add_dependency remove_dependency next)
  def actions, do: @actions
end
