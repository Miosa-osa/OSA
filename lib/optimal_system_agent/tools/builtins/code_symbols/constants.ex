defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "code_symbols"
  def tool_name, do: @tool_name

  @default_allowed_paths ["~", "/tmp"]
  def default_allowed_paths, do: @default_allowed_paths

  @supported_extensions ~w(.ex .exs .py .js .ts .jsx .tsx .go .rs .rb .java .kt)
  def supported_extensions, do: @supported_extensions
end
