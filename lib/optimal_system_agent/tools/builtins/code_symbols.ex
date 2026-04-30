defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols do
  @moduledoc """
  Shim — delegates all behaviour callbacks to the structured-layout
  `OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool` module.

  Preserved so that any existing callers using the flat module name
  (`OptimalSystemAgent.Tools.Builtins.CodeSymbols`) continue to work without
  change. The registry receives `CodeSymbols.Tool` via the normal structured-
  layout path.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate available?(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate should_defer?(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate always_load?(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate strict?(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool

  defdelegate concurrency_safe?(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool

  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate interrupt_behavior(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate max_result_size_chars(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool

  defdelegate check_permissions(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool

  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate deferred?(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
  defdelegate concurrent?(), to: OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool
end
