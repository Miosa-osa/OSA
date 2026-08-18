defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "code_symbols"
  def tool_name, do: @tool_name

  @supported_extensions ~w(.ex .exs .py .js .ts .jsx .tsx .go .rs .rb .java .kt)
  def supported_extensions, do: @supported_extensions
end
