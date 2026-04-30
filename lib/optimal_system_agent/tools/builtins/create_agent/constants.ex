defmodule OptimalSystemAgent.Tools.Builtins.CreateAgent.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  `ListAgents.Prompt` references `tool_name/0` here so a rename propagates
  automatically.
  """

  @tool_name "create_agent"
  def tool_name, do: @tool_name

  @agents_base_dir "~/.osa/agents"
  def agents_base_dir, do: @agents_base_dir

  @valid_tiers ~w(elite specialist utility)
  def valid_tiers, do: @valid_tiers
end
