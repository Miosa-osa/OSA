defmodule OptimalSystemAgent.Tools.Builtins.DirList do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives under `lib/optimal_system_agent/tools/builtins/dir_list/`:

    * `DirList.Tool`      — `use OptimalSystemAgent.Tools.Behaviour`, declarations
    * `DirList.Constants` — exported atoms for cross-tool reference
    * `DirList.Prompt`    — dynamic prompt builder
    * `DirList.Handler`   — validate / check_permissions / execute
    * `DirList.UI`        — render callbacks for the Rust TUI

  This module preserves the `OptimalSystemAgent.Tools.Builtins.DirList` atom
  so that existing registry entries, config references, and test aliases
  continue to resolve without modification.
  """

  defdelegate name, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate description, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate parameters, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate safety, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate available?, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate aliases, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate search_hint, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate prompt(opts), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate should_defer?, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate always_load?, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate concurrency_safe?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate read_only?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate destructive?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate open_world?(input, ctx), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate max_result_size_chars, to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate validate_input(input, ctx), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate check_permissions(input, ctx), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate execute(input, ctx), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate render(stage, payload, opts), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
  defdelegate to_classifier_input(input), to: OptimalSystemAgent.Tools.Builtins.DirList.Tool
end
