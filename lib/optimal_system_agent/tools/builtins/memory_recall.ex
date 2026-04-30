defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall do
  @moduledoc """
  Shim preserving the flat-layout module name.

  All implementation lives in the structured layout under
  `lib/optimal_system_agent/tools/builtins/memory_recall/`.

  The registry and any existing callers that reference this module name
  will continue to work — the shim delegates every callback to
  `MemoryRecall.Tool`, which is the structured-layout entry point.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate should_defer?(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate always_load?(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool

  defdelegate concurrency_safe?(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool

  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool

  defdelegate check_permissions(input, ctx),
    to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool

  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool

  defdelegate render(stage, payload, opts),
    to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool

  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool
end
