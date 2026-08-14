defmodule OptimalSystemAgent.Tools.Builtins.FileTransform.Constants do
  @moduledoc """
  Exported constants for cross-tool prompt references.

  Mirrors `FileWrite.Constants`: other tools' prompts reference `tool_name/0`
  through `safe_ref/3`, so a rename propagates without a grep.
  """

  @tool_name "file_transform"
  def tool_name, do: @tool_name
end
