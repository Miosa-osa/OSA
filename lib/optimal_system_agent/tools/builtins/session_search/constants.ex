defmodule OptimalSystemAgent.Tools.Builtins.SessionSearch.Constants do
  @moduledoc """
  Exported constants for cross-tool references.

  Other prompts that reference the session_search tool name should use
  `safe_ref/3` against this module so a rename propagates automatically.
  """

  @tool_name "session_search"
  def tool_name, do: @tool_name

  # FTS5-backed search is tried first; falls back to Memory.search_sessions.
  @default_limit 10
  def default_limit, do: @default_limit

  # Hard cap on result text returned to the model (chars).
  @max_result_size_chars 50_000
  def max_result_size_chars, do: @max_result_size_chars

  # Preview characters per result entry.
  @content_preview_chars 200
  def content_preview_chars, do: @content_preview_chars
end
