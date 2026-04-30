defmodule OptimalSystemAgent.Tools.Builtins.ListAgents.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts (e.g. `CreateAgent.Prompt`, `Delegate.Prompt`) reference
  `tool_name/0` so a rename here propagates everywhere automatically.
  """

  @tool_name "list_agents"
  def tool_name, do: @tool_name
end
