defmodule OptimalSystemAgent.Tools.Builtins.REPL.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "repl"
  def tool_name, do: @tool_name

  @supported_languages ["python", "elixir", "node"]
  def supported_languages, do: @supported_languages

  @default_timeout_ms 30_000
  def default_timeout_ms, do: @default_timeout_ms
end
