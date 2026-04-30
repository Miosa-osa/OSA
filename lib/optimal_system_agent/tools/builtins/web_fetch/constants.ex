defmodule OptimalSystemAgent.Tools.Builtins.WebFetch.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Other tools' prompts can reference `tool_name/0` so a rename propagates
  automatically. Mirrors the constants pattern from FileRead.Constants.
  """

  @tool_name "web_fetch"
  def tool_name, do: @tool_name

  @default_max_length 10_000
  def default_max_length, do: @default_max_length

  @max_download_bytes 1_048_576
  def max_download_bytes, do: @max_download_bytes

  @max_redirects 3
  def max_redirects, do: @max_redirects
end
