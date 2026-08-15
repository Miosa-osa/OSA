defmodule OptimalSystemAgent.Tools.Builtins.REPL do
  @moduledoc """
  Shim — delegates all behaviour callbacks to the structured-layout
  `OptimalSystemAgent.Tools.Builtins.REPL.Tool` module.

  Preserved so that any existing callers using the flat module name
  (`OptimalSystemAgent.Tools.Builtins.REPL`) continue to work without
  change. The registry receives `REPL.Tool` via the normal structured-
  layout path.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate available?(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate should_defer?(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate always_load?(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate strict?(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate concurrency_safe?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate max_result_size_chars(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate check_permissions(input, ctx), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate deferred?(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
  defdelegate concurrent?(), to: OptimalSystemAgent.Tools.Builtins.REPL.Tool
end
