defmodule OptimalSystemAgent.Tools.Builtins.TeamTasks do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives in:
    `lib/optimal_system_agent/tools/builtins/team_tasks/`

  This file exists only so existing callers that reference
  `OptimalSystemAgent.Tools.Builtins.TeamTasks` by atom continue to compile.
  The registry picks up the structured `Tool` module directly; this shim is
  retained for legacy call-site compatibility.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.TeamTasks.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.TeamTasks.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.TeamTasks.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.TeamTasks.Tool

  # Flat-layout callers pass only input — bridge to structured execute/2 with nil ctx.
  def execute(input),
    do: OptimalSystemAgent.Tools.Builtins.TeamTasks.Handler.execute(input, nil)
end
