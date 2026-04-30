defmodule OptimalSystemAgent.Speculative.Tools.StartSpeculative do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives under `lib/optimal_system_agent/speculative/tools/start_speculative/`:

    * `StartSpeculative.Tool`      — `use OptimalSystemAgent.Tools.Behaviour`, declarations
    * `StartSpeculative.Constants` — exported atoms for cross-tool reference
    * `StartSpeculative.Prompt`    — dynamic prompt builder
    * `StartSpeculative.Handler`   — validate / execute
    * `StartSpeculative.UI`        — render callbacks for the Rust TUI

  This module preserves the `OptimalSystemAgent.Speculative.Tools.StartSpeculative` atom
  so that existing registry entries, config references, and test aliases
  continue to resolve without modification.
  """

  @tool OptimalSystemAgent.Speculative.Tools.StartSpeculative.Tool

  defdelegate name, to: @tool
  defdelegate description, to: @tool
  defdelegate parameters, to: @tool
  defdelegate safety, to: @tool
  defdelegate available?, to: @tool
  defdelegate aliases, to: @tool
  defdelegate search_hint, to: @tool
  defdelegate prompt(opts), to: @tool
  defdelegate should_defer?, to: @tool
  defdelegate always_load?, to: @tool
  defdelegate concurrency_safe?(input, ctx), to: @tool
  defdelegate read_only?(input, ctx), to: @tool
  defdelegate destructive?(input, ctx), to: @tool
  defdelegate open_world?(input, ctx), to: @tool
  defdelegate max_result_size_chars, to: @tool
  defdelegate validate_input(input, ctx), to: @tool
  defdelegate check_permissions(input, ctx), to: @tool
  defdelegate execute(input, ctx), to: @tool
  defdelegate render(stage, payload, opts), to: @tool
  defdelegate to_classifier_input(input), to: @tool
end
