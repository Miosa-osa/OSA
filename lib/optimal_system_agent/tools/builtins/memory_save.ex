defmodule OptimalSystemAgent.Tools.Builtins.MemorySave do
  @moduledoc """
  Shim preserving the flat-layout module name.

  All implementation lives in the structured layout under
  `lib/optimal_system_agent/tools/builtins/memory_save/`.

  The registry and any existing callers that reference this module name
  will continue to work — the shim delegates every callback to
  `MemorySave.Tool`, which is the structured-layout entry point.
  """

  defdelegate name(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate aliases(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate search_hint(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate description(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate parameters(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate should_defer?(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate always_load?(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate concurrency_safe?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate safety(), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate check_permissions(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.MemorySave.Tool
end
