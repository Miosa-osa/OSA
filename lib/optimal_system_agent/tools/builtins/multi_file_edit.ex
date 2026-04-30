defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit do
  @moduledoc """
  Shim — delegates all behaviour callbacks to the structured-layout
  `OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool` module.

  Preserved so that any existing callers using the flat module name
  (`OptimalSystemAgent.Tools.Builtins.MultiFileEdit`) continue to work without
  change. The registry receives `MultiFileEdit.Tool` via the normal structured-
  layout path.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate available?(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate should_defer?(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate always_load?(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate strict?(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool

  defdelegate concurrency_safe?(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool

  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate interrupt_behavior(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate max_result_size_chars(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool

  defdelegate check_permissions(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool

  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool

  defdelegate render(stage, payload, opts),
    to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool

  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate deferred?(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
  defdelegate concurrent?(), to: OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool
end
