defmodule OptimalSystemAgent.Verification.Tools.VerifyLoop do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives under `lib/optimal_system_agent/verification/tools/verify_loop/`:

    * `VerifyLoop.Tool`      — `use OptimalSystemAgent.Tools.Behaviour`, declarations
    * `VerifyLoop.Constants` — exported atoms for cross-tool reference
    * `VerifyLoop.Prompt`    — dynamic prompt builder
    * `VerifyLoop.Handler`   — validate / execute
    * `VerifyLoop.UI`        — render callbacks for the Rust TUI

  This module preserves the `OptimalSystemAgent.Verification.Tools.VerifyLoop` atom
  so that existing registry entries, config references, and test aliases
  continue to resolve without modification.
  """

  @tool OptimalSystemAgent.Verification.Tools.VerifyLoop.Tool

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
