defmodule OptimalSystemAgent.Tools.Builtins.BashOutput.Constants do
  @moduledoc """
  Exported constants for `bash_output`. Other prompts can reference
  `tool_name/0` so a rename propagates automatically.
  """

  @tool_name "bash_output"
  def tool_name, do: @tool_name
end
