defmodule OptimalSystemAgent.Tools.Builtins.Download do
  @moduledoc """
  Shim — delegates all behaviour callbacks to the structured-layout
  `OptimalSystemAgent.Tools.Builtins.Download.Tool` module.

  Preserved so that any existing callers using the flat module name
  (`OptimalSystemAgent.Tools.Builtins.Download`) continue to work without
  change. The registry receives `Download.Tool` via the normal structured-
  layout path.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate available?(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate should_defer?(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate always_load?(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate strict?(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate concurrency_safe?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate interrupt_behavior(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate max_result_size_chars(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate check_permissions(input, ctx), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate deferred?(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
  defdelegate concurrent?(), to: OptimalSystemAgent.Tools.Builtins.Download.Tool
end
