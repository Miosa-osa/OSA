defmodule OptimalSystemAgent.Tools.Builtins.MessageAgent do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives in:
    `lib/optimal_system_agent/tools/builtins/message_agent/`

  This file exists only so existing callers that reference
  `OptimalSystemAgent.Tools.Builtins.MessageAgent` by atom continue to compile.
  The registry picks up the structured `Tool` module directly; this shim is
  retained for legacy call-site compatibility.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.MessageAgent.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.MessageAgent.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.MessageAgent.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.MessageAgent.Tool

  # Flat-layout callers pass only input — bridge to structured execute/2 with nil ctx.
  def execute(input),
    do: OptimalSystemAgent.Tools.Builtins.MessageAgent.Handler.execute(input, nil)
end
