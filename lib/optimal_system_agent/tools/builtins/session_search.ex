defmodule OptimalSystemAgent.Tools.Builtins.SessionSearch do
  @moduledoc """
  Thin shim — delegates entirely to the structured per-tool directory layout.

  The real implementation lives in:

      lib/optimal_system_agent/tools/builtins/session_search/
      ├── tool.ex        — `use OptimalSystemAgent.Tools.Behaviour`, callbacks
      ├── prompt.ex      — dynamic prompt
      ├── handler.ex     — validate / check_permissions / execute
      ├── ui.ex          — render/3 for the Rust TUI
      └── constants.ex   — tool_name/0, default_limit/0, max_result_size_chars/0

  This module exists so:
  1. The registry keeps the same atom `OptimalSystemAgent.Tools.Builtins.SessionSearch`.
  2. Existing test aliases (`alias ... SessionSearch`) continue to resolve.
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.SessionSearch.Tool

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Tool.name()

  @impl true
  def aliases, do: Tool.aliases()

  @impl true
  def search_hint, do: Tool.search_hint()

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Tool.description()

  @impl true
  def prompt(opts), do: Tool.prompt(opts)

  @impl true
  def parameters, do: Tool.parameters()

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def available?, do: Tool.available?()

  @impl true
  def should_defer?, do: Tool.should_defer?()

  @impl true
  def always_load?, do: Tool.always_load?()

  @impl true
  def strict?, do: Tool.strict?()

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  def concurrency_safe?(input, ctx), do: Tool.concurrency_safe?(input, ctx)

  @impl true
  def read_only?(input, ctx), do: Tool.read_only?(input, ctx)

  @impl true
  def destructive?(input, ctx), do: Tool.destructive?(input, ctx)

  @impl true
  def open_world?(input, ctx), do: Tool.open_world?(input, ctx)

  @impl true
  def interrupt_behavior, do: Tool.interrupt_behavior()

  @impl true
  def max_result_size_chars, do: Tool.max_result_size_chars()

  # ── Two-stage permissioning ───────────────────────────────────────────
  @impl true
  def validate_input(input, ctx), do: Tool.validate_input(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Tool.check_permissions(input, ctx)

  # ── Execution ─────────────────────────────────────────────────────────

  # Structured execute/2 — used by LegacyAdapter when it detects execute/2.
  @impl true
  def execute(input, ctx), do: Tool.execute(input, ctx)

  # Flat execute/1 — kept so existing call sites without a UseContext work.
  @impl true
  def execute(input) do
    ctx = %OptimalSystemAgent.Tools.UseContext{session_id: nil}
    Tool.execute(input, ctx)
  end

  # ── Rendering & classification ────────────────────────────────────────
  @impl true
  def render(stage, payload, opts), do: Tool.render(stage, payload, opts)

  @impl true
  def to_classifier_input(input), do: Tool.to_classifier_input(input)

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: Tool.safety()

  @impl true
  def deferred?, do: Tool.deferred?()

  @impl true
  def concurrent?, do: Tool.concurrent?()
end
