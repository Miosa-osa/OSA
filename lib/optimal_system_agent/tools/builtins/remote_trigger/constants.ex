defmodule OptimalSystemAgent.Tools.Builtins.RemoteTrigger.Constants do
  @moduledoc "Exported constants for the remote_trigger tool."

  @tool_name "remote_trigger"
  def tool_name, do: @tool_name

  @actions ~w(fire create remove list)
  def actions, do: @actions
end
