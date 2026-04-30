defmodule OptimalSystemAgent.Verification.Tools.VerifyLoop.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.
  """

  @tool_name "verify_loop"
  def tool_name, do: @tool_name

  @default_max_iterations 5
  def default_max_iterations, do: @default_max_iterations

  @min_iterations 1
  def min_iterations, do: @min_iterations

  @max_iterations 20
  def max_iterations, do: @max_iterations
end
