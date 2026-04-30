defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgents do
  @moduledoc """
  Shim — delegates to the structured per-tool directory layout.

  All logic lives in `lib/optimal_system_agent/tools/builtins/mixture_of_agents/`.
  This module is kept for registry backwards-compatibility and for tests
  that alias `MixtureOfAgents` directly; it forwards every callback to
  `MixtureOfAgents.Tool`.
  """

  @tool OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Tool

  defdelegate name(), to: @tool
  defdelegate description(), to: @tool
  defdelegate parameters(), to: @tool
  defdelegate safety(), to: @tool
  defdelegate deferred?(), to: @tool
  defdelegate concurrent?(), to: @tool
  defdelegate available?(), to: @tool
  defdelegate should_defer?(), to: @tool
  defdelegate concurrency_safe?(input, ctx), to: @tool
  defdelegate read_only?(input, ctx), to: @tool
  defdelegate validate_input(input, ctx), to: @tool
  defdelegate check_permissions(input, ctx), to: @tool
  defdelegate execute(input, ctx), to: @tool
  defdelegate render(stage, payload, opts), to: @tool
  defdelegate prompt(opts), to: @tool
  defdelegate to_classifier_input(input), to: @tool
end
