defmodule OptimalSystemAgent.Tools.Builtins.Sleep.Constants do
  @moduledoc "Exported constants for the sleep tool."

  @tool_name "sleep"
  def tool_name, do: @tool_name

  @max_seconds 3600
  def max_seconds, do: @max_seconds

  @min_seconds 1
  def min_seconds, do: @min_seconds
end
