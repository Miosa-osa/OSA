defmodule OptimalSystemAgent.Tools.Builtins.WebSearch.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts can reference `tool_name/0` so a rename propagates
  automatically. Mirrors the constants pattern from FileRead.Constants.
  """

  @tool_name "web_search"
  def tool_name, do: @tool_name

  @default_limit 5
  def default_limit, do: @default_limit

  @ddg_url "https://html.duckduckgo.com/html/"
  def ddg_url, do: @ddg_url
end
