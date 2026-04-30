defmodule OptimalSystemAgent.Tools.Builtins.CreateAgent do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives in:
    `lib/optimal_system_agent/tools/builtins/create_agent/`

  This file exists only so existing callers that reference
  `OptimalSystemAgent.Tools.Builtins.CreateAgent` by atom continue to compile.
  The registry picks up the structured `Tool` module directly; this shim is
  retained for legacy call-site compatibility.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.CreateAgent.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.CreateAgent.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.CreateAgent.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.CreateAgent.Tool

  # Flat-layout callers pass only input — bridge to structured execute/2 with nil ctx.
  def execute(input),
    do: OptimalSystemAgent.Tools.Builtins.CreateAgent.Handler.execute(input, nil)
end
