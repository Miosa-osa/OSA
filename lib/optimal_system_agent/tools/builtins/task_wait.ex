defmodule OptimalSystemAgent.Tools.Builtins.TaskWait do
  @moduledoc """
  Shim for the structured task_wait tool.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.TaskWait.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.TaskWait.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.TaskWait.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.TaskWait.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.TaskWait.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.TaskWait.Tool
end
