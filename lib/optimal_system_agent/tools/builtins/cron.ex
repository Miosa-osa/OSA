defmodule OptimalSystemAgent.Tools.Builtins.Cron do
  @moduledoc """
  Shim — delegates to the structured-layout module at `builtins/cron/`.

  The implementation has been migrated to the per-tool directory layout
  (Pillar F). This module exists only so that existing references to
  `OptimalSystemAgent.Tools.Builtins.Cron` continue to resolve without
  changes to the registry or any callers.

  All behaviour callbacks are forwarded to `Cron.Tool`, which `use`s
  `OptimalSystemAgent.Tools.Behaviour` and implements the full structured
  contract.
  """

  @target OptimalSystemAgent.Tools.Builtins.Cron.Tool

  defdelegate name(), to: @target
  defdelegate aliases(), to: @target
  defdelegate search_hint(), to: @target
  defdelegate description(), to: @target
  defdelegate parameters(), to: @target
  defdelegate prompt(opts), to: @target
  defdelegate should_defer?(), to: @target
  defdelegate always_load?(), to: @target
  defdelegate safety(), to: @target
  defdelegate deferred?(), to: @target
  defdelegate concurrent?(), to: @target
  defdelegate available?(), to: @target
  defdelegate strict?(), to: @target
  defdelegate concurrency_safe?(input, ctx), to: @target
  defdelegate read_only?(input, ctx), to: @target
  defdelegate destructive?(input, ctx), to: @target
  defdelegate open_world?(input, ctx), to: @target
  defdelegate interrupt_behavior(), to: @target
  defdelegate max_result_size_chars(), to: @target
  defdelegate validate_input(input, ctx), to: @target
  defdelegate check_permissions(input, ctx), to: @target
  defdelegate execute(input, ctx), to: @target
  defdelegate render(stage, payload, opts), to: @target
  defdelegate to_classifier_input(input), to: @target
end
