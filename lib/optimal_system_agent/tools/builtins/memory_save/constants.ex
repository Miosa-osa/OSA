defmodule OptimalSystemAgent.Tools.Builtins.MemorySave.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts (e.g. `MemoryRecall.Prompt`) reference
  `tool_name/0` so a rename here propagates everywhere automatically.
  """

  @tool_name "memory_save"
  def tool_name, do: @tool_name

  @valid_categories ~w(decision preference pattern lesson context project)
  def valid_categories, do: @valid_categories
end
