defmodule OptimalSystemAgent.Tools.Builtins.TaskTranscript do
  @moduledoc """
  Shim for the structured task_transcript tool.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool
end
