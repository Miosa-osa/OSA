defmodule OptimalSystemAgent.Tools.Builtins.UseTool.Prompt do
  @moduledoc """
  Dynamic prompt for `use_tool`.

  Mirrors grok-build's `use_tool` meta-dispatch tool: once a large MCP toolset
  is virtualized, the raw tools are no longer in the base tool list, so the
  model cannot emit a native function call for them. `use_tool` is the stable,
  always-present dispatcher — its presence keeps the tool set constant across
  turns (no KV-cache churn as new tools are discovered) while still letting the
  model invoke anything `tool_search` surfaces.
  """

  @body ~S"""
  Invokes a virtualized tool that was discovered via `tool_search` but is not
  present in the base tool list.

  Pass the fully-qualified tool name exactly as returned by `tool_search`
  (e.g. "mcp__linear__create_issue") plus an arguments object matching that
  tool's parameter schema.

  Use this ONLY for deferred / virtualized tools. Any tool already listed at the
  top of the prompt must be called directly — calling it through `use_tool`
  returns a corrective error.

  Workflow: `tool_search` to discover the qualified name and its schema →
  `use_tool` with that name and the matching arguments.
  """

  @doc "Render the use_tool prompt."
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []), do: @body
end
