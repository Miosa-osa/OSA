defmodule OptimalSystemAgent.Tools.Builtins.ToolSearch.Constants do
  @moduledoc """
  Exported constants for `tool_search`.

  Mirrors `src/tools/ToolSearchTool/constants.ts`. Other tools' prompts
  reference `tool_name/0` so a rename here propagates automatically.

  NOTE: the canonical Claude Code name is "ToolSearch" (PascalCase). OSA
  uses snake_case consistently for builtin tool names, so the name is
  "tool_search". Cross-tool references should import this constant, not
  hardcode the string.
  """

  @tool_name "tool_search"
  def tool_name, do: @tool_name

  @default_max_results 5
  def default_max_results, do: @default_max_results

  @max_result_size_chars 100_000
  def max_result_size_chars, do: @max_result_size_chars
end
