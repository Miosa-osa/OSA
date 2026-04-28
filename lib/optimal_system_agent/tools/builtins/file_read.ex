defmodule OptimalSystemAgent.Tools.Builtins.FileRead do
  @moduledoc """
  Backwards-compat shim — the real implementation lives at
  `OptimalSystemAgent.Tools.Builtins.FileRead.Tool` (per-tool directory).

  This shim exists only to keep external callers that imported the
  flat-module path from breaking during Phase 1. Phase 5 will remove
  this module after auditing for direct imports.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileRead.Tool

  defdelegate name(), to: Tool
  defdelegate description(), to: Tool
  defdelegate parameters(), to: Tool
  defdelegate safety(), to: Tool
  defdelegate available?(), to: Tool

  @doc "v1 entry point — delegates through the v2 tool with an empty UseContext."
  def execute(input) do
    OptimalSystemAgent.Tools.LegacyAdapter.execute(
      Tool,
      input,
      OptimalSystemAgent.Tools.UseContext.empty()
    )
  end
end
