defmodule OptimalSystemAgent.Tools.Builtins.TaskList do
  @moduledoc """
  Shim for the structured task_list tool.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.TaskList.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.TaskList.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.TaskList.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.TaskList.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.TaskList.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.TaskList.Tool
  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.TaskList.Tool
end
