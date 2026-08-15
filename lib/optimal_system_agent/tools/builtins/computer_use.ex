defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse do
  @moduledoc """
  Shim — delegates every callback to the structured-layout entry point.

  **Do not add logic here.** All implementation lives in:

      lib/optimal_system_agent/tools/builtins/computer_use/
      ├── tool.ex        ← full Behaviour implementation
      ├── prompt.ex      ← dynamic prompt
      ├── handler.ex     ← validate / check_permissions / execute
      ├── ui.ex          ← Rust TUI render payloads
      ├── constants.ex   ← action atoms, limits, ETS table name
      ├── adapter.ex     ← platform adapter behaviour + detection
      ├── server.ex      ← lazy GenServer per session
      ├── executor.ex    ← low-level action dispatch
      ├── planner.ex     ← multi-step planning helper
      ├── keyframe.ex    ← trajectory journal + doom-loop detection
      ├── accessibility.ex
      ├── shared.ex
      └── adapters/      ← mac / linux / docker / x11 / remote_ssh / platform_vm

  Migration: flat → structured (registry sees uniform structured surface via LegacyAdapter).
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Tool

  # ── Identity ──────────────────────────────────────────────────────────
  defdelegate name(), to: Tool
  defdelegate aliases(), to: Tool
  defdelegate search_hint(), to: Tool

  # ── Schema & description ──────────────────────────────────────────────
  defdelegate description(), to: Tool
  defdelegate parameters(), to: Tool

  def prompt(opts), do: Tool.prompt(opts)

  # ── Loading semantics ─────────────────────────────────────────────────
  defdelegate available?(), to: Tool
  defdelegate should_defer?(), to: Tool
  defdelegate always_load?(), to: Tool
  defdelegate strict?(), to: Tool

  # ── Execution semantics ───────────────────────────────────────────────
  def concurrency_safe?(input, ctx), do: Tool.concurrency_safe?(input, ctx)
  def read_only?(input, ctx), do: Tool.read_only?(input, ctx)
  def destructive?(input, ctx), do: Tool.destructive?(input, ctx)
  def open_world?(input, ctx), do: Tool.open_world?(input, ctx)
  defdelegate max_result_size_chars(), to: Tool

  # ── Two-stage permissioning ───────────────────────────────────────────
  def validate_input(input, ctx), do: Tool.validate_input(input, ctx)
  def check_permissions(input, ctx), do: Tool.check_permissions(input, ctx)

  # ── Execution ─────────────────────────────────────────────────────────
  def execute(input, ctx), do: Tool.execute(input, ctx)

  # Flat-layout callers that still invoke execute/1 (e.g. direct test calls)
  # route through LegacyAdapter so they get the full
  # validate → check_permissions → execute pipeline (not just bare Handler.execute).
  def execute(input) do
    OptimalSystemAgent.Tools.LegacyAdapter.execute(
      Tool,
      input,
      OptimalSystemAgent.Tools.UseContext.empty()
    )
  end

  # ── Rendering ─────────────────────────────────────────────────────────
  def render(stage, payload, opts), do: Tool.render(stage, payload, opts)
  def to_classifier_input(input), do: Tool.to_classifier_input(input)

  # ── Flat-layout compatibility ─────────────────────────────────────────
  defdelegate safety(), to: Tool
  defdelegate deferred?(), to: Tool
  defdelegate concurrent?(), to: Tool
end
