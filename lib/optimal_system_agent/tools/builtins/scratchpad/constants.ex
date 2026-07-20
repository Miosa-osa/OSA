defmodule OptimalSystemAgent.Tools.Builtins.Scratchpad.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "scratchpad"
  def tool_name, do: @tool_name

  @valid_actions ~w(write append read list delete)
  def valid_actions, do: @valid_actions
end
