defmodule OptimalSystemAgent.Tools.Builtins.MessageAgent.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  `TeamTasks.Prompt` references `tool_name/0` here so a rename propagates
  automatically.
  """

  @tool_name "message_agent"
  def tool_name, do: @tool_name

  @valid_actions ~w(send read broadcast)
  def valid_actions, do: @valid_actions
end
