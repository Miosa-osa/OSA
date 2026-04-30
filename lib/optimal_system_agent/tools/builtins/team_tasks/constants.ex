defmodule OptimalSystemAgent.Tools.Builtins.TeamTasks.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "team_tasks"
  def tool_name, do: @tool_name

  @valid_actions ~w(list claim complete scratchpad_write scratchpad_read)
  def valid_actions, do: @valid_actions
end
