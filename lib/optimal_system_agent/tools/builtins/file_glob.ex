defmodule OptimalSystemAgent.Tools.Builtins.FileGlob do
  @moduledoc """
  Backwards-compat shim — the real implementation lives at
  `OptimalSystemAgent.Tools.Builtins.FileGlob.Tool` (per-tool directory).

  This shim exists only to keep external callers that imported the
  flat-module path from breaking during Phase 3b. Phase 5 will remove
  this module after auditing for direct imports.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileGlob.Tool

  defdelegate name(), to: Tool
  defdelegate description(), to: Tool
  defdelegate parameters(), to: Tool
  defdelegate safety(), to: Tool
  defdelegate available?(), to: Tool

  @doc "Flat-layout entry point — delegates through the structured tool with an empty UseContext."
  def execute(input) do
    OptimalSystemAgent.Tools.LegacyAdapter.execute(
      Tool,
      input,
      OptimalSystemAgent.Tools.UseContext.empty()
    )
  end
end
