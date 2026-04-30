defmodule OptimalSystemAgent.Tools.Builtins.Git do
  @moduledoc """
  Shim — delegates every callback to the structured-layout implementation.

  The authoritative implementation now lives in:

      lib/optimal_system_agent/tools/builtins/git/
      ├── tool.ex       — callbacks (use Behaviour)
      ├── prompt.ex     — Git Safety Protocol prompt
      ├── handler.ex    — validate / check_permissions / execute
      ├── ui.ex         — render/3 for the Rust TUI
      └── constants.ex  — tool_name/0 and safety constants

  This file exists only so that any code still referencing the flat module
  name `OptimalSystemAgent.Tools.Builtins.Git` continues to compile and
  dispatch correctly without modification. The behaviour is satisfied by
  `Git.Tool`, which uses `OptimalSystemAgent.Tools.Behaviour` directly.
  """

  alias OptimalSystemAgent.Tools.Builtins.Git.Tool

  defdelegate name(), to: Tool
  defdelegate aliases(), to: Tool
  defdelegate search_hint(), to: Tool
  defdelegate description(), to: Tool
  defdelegate parameters(), to: Tool
  defdelegate safety(), to: Tool
  defdelegate should_defer?(), to: Tool
  defdelegate always_load?(), to: Tool

  defdelegate concurrency_safe?(input, ctx), to: Tool
  defdelegate read_only?(input, ctx), to: Tool
  defdelegate destructive?(input, ctx), to: Tool

  defdelegate validate_input(input, ctx), to: Tool
  defdelegate check_permissions(input, ctx), to: Tool

  defdelegate execute(input, ctx), to: Tool
  defdelegate execute(input), to: Tool

  defdelegate render(stage, payload, opts), to: Tool
  defdelegate to_classifier_input(input), to: Tool
  defdelegate prompt(opts), to: Tool
end
