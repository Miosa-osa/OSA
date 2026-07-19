defmodule OptimalSystemAgent.Tools.Builtins.UseTool.Constants do
  @moduledoc """
  Exported constants for `use_tool`.

  Cross-tool references (prompts, tests) should import `tool_name/0` rather
  than hardcoding the string so a rename propagates automatically.
  """

  @tool_name "use_tool"
  def tool_name, do: @tool_name

  # Meta-tools that `use_tool` must never dispatch to — invoking them through
  # the dispatcher is either nonsensical (`use_tool` calling itself) or a
  # discovery step the model should perform directly (`tool_search`).
  @meta_tools ["use_tool", "tool_search"]
  def meta_tools, do: @meta_tools
end
