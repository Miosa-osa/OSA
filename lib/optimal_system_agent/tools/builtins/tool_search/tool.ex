defmodule OptimalSystemAgent.Tools.Builtins.ToolSearch.Tool do
  @moduledoc """
  Structured-layout tool implementation for `tool_search`.

  This is the lazy-loading mechanism for OSA's Phase 3b prompt-token
  reduction. It is the ONLY tool that must NEVER be deferred — the model
  needs it available from turn 1 so it can fetch any other deferred tool.

  Per-tool directory layout:
    * `ToolSearch.Constants`  — exported atoms (tool name)
    * `ToolSearch.Prompt`     — dynamic prompt builder (mirrors prompt.ts:27-51)
    * `ToolSearch.Handler`    — validate / check_permissions / execute
    * `ToolSearch.UI`         — render callbacks for the Rust TUI

  Loading semantics (mirrors isDeferredTool logic at prompt.ts:62-108):
    * `should_defer?/0` → false — CRITICAL. tool_search itself is NEVER
      deferred. The model cannot fetch deferred tools without it.
    * `always_load?/0`  → true  — force-included in turn 1 even if the
      PromptAssembler would otherwise skip it.

  Execution semantics: pure registry lookup. No writes, no side effects.
    * `concurrency_safe?/2` → true
    * `read_only?/2`        → true
    * `destructive?/2`      → false
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ToolSearch.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["search_tools", "find_tool"]

  @impl true
  def search_hint, do: "discover and load deferred tools by keyword or exact name"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" =>
            ~S|Query to find deferred tools. Use "select:<tool_name>" for direct selection, or keywords to search. Examples: "select:Read,Edit,Grep" · "notebook jupyter" · "+slack send"|
        },
        "max_results" => %{
          "type" => "integer",
          "description" =>
            "Maximum number of results to return (default: #{Constants.default_max_results()})"
        }
      },
      "required" => ["query"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────

  # CRITICAL: tool_search must NEVER be deferred.
  # Mirrors the explicit guard at prompt.ts:71:
  #   if (tool.name === TOOL_SEARCH_TOOL_NAME) return false
  # If this returned true the model would have no way to load any tool.
  @impl true
  def should_defer?, do: false

  # Force-include in turn 1 prompt so the model sees it immediately.
  # Mirrors alwaysLoad: true / _meta['anthropic/alwaysLoad'] in the CC
  # reference (see isDeferredTool check at prompt.ts:65).
  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────

  # Pure registry lookup — safe to run concurrently with anything.
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  # Matches maxResultSizeChars: 100_000 in ToolSearchTool.ts.
  # Needed because returning many full tool schemas can exceed the default
  # 30_000-char limit and trigger spurious result-storage writes.
  def max_result_size_chars, do: Constants.max_result_size_chars()

  # ── Flat-layout compatibility ──────────────────────────────────────────────────
  @impl true
  def safety, do: :read_only

  # ── Two-stage permissioning ───────────────────────────────────────────
  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ─────────────────────────────────────────────────────────
  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ─────────────────────────────────────────────────────────
  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ──────────────────────────────────────────────────
  @impl true
  def to_classifier_input(%{"query" => q}), do: %{query: q}
  def to_classifier_input(_), do: ""
end
