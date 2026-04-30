defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit do
  @moduledoc """
  Backwards-compat shim — the real implementation lives at
  `OptimalSystemAgent.Tools.Builtins.NotebookEdit.Tool` (per-tool directory).

  This shim exists only to keep external callers that use the flat-module
  path from breaking. Remove after auditing for direct imports.

  ## Preserved surface
    * `name/0`, `description/0`, `parameters/0`, `safety/0`, `available?/0`
      — delegates directly to Tool.
    * `execute/1` — delegates through LegacyAdapter with an empty UseContext,
      identical to the FileEdit shim pattern.
  """

  alias OptimalSystemAgent.Tools.Builtins.NotebookEdit.Tool

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
