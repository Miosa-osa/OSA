defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts (e.g. `MemorySave.Prompt`) reference
  `tool_name/0` so a rename here propagates everywhere automatically.
  """

  @tool_name "memory_recall"
  def tool_name, do: @tool_name

  @valid_categories ~w(decision preference pattern lesson context project)
  def valid_categories, do: @valid_categories

  @default_limit 10
  def default_limit, do: @default_limit
end
