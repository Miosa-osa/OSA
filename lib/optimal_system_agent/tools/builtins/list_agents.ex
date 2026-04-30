defmodule OptimalSystemAgent.Tools.Builtins.ListAgents do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives in:
    `lib/optimal_system_agent/tools/builtins/list_agents/`

  This file exists only so existing callers that reference
  `OptimalSystemAgent.Tools.Builtins.ListAgents` by atom continue to compile.
  The registry picks up the structured `Tool` module directly; this shim is
  retained for legacy call-site compatibility.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.ListAgents.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.ListAgents.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.ListAgents.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.ListAgents.Tool

  # Flat-layout callers pass only input — bridge to structured execute/2 with nil ctx.
  def execute(input),
    do: OptimalSystemAgent.Tools.Builtins.ListAgents.Handler.execute(input, nil)
end
