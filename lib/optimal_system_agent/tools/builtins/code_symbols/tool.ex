defmodule OptimalSystemAgent.Tools.Builtins.CodeSymbols.Tool do
  @moduledoc """
  Structured-layout tool implementation for `code_symbols`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `CodeSymbols.Constants`  — exported atoms for cross-tool reference
    * `CodeSymbols.Prompt`     — dynamic prompt builder
    * `CodeSymbols.Handler`    — validate / check_permissions / execute
    * `CodeSymbols.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.CodeSymbols.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["symbols", "list_symbols"]

  @impl true
  def search_hint, do: "list functions, classes, and modules in a source file"

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
        "path" => %{
          "type" => "string",
          "description" => "Path to the source file to analyze"
        },
        "type" => %{
          "type" => "string",
          "description" =>
            "Filter by symbol type: \"function\", \"class\", \"module\". Omit for all symbols."
        }
      },
      "required" => ["path"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # DEFERRED, overriding an earlier deliberate `false`.
  #
  # The original reasoning was that this should be usable from turn 1. That is
  # a testable claim and the measurement contradicts it: across 15 SWE-bench Pro
  # transcripts covering 863 turns and 963 tool calls, this tool was invoked
  # ZERO times while its schema was re-sent on every single request.
  #
  # Reason it is safe to defer: symbol lookup, a specialist surface over file_grep, which is always loaded.
  #
  # Nothing is lost — deferred tools stay registered and discoverable mid-turn
  # through `tool_search`. What changes is that the model is no longer billed
  # for a description it never reads.
  #
  # Reopen this if a workload appears where it IS called early. The measurement
  # is from coding tasks; it is not a claim about every workload.
  def should_defer?, do: true

  @impl true
  # `false`, and the reason is a defect this contradiction was hiding.
  #
  # `should_defer?` above already says this tool is not worth its schema on
  # every request. `always_load?` said the opposite, and the two are read by
  # DIFFERENT consumers that never compared notes:
  #
  #   * `Tools.PromptAssembler.partition/2` honours `always_load?`, so the full
  #     prose AND a re-encoded JSON schema went into the system prompt.
  #   * `Tools.Registry.list_active/0` — which is the sole source of the native
  #     `tools` array (`Registry.filter_applicable_tools/1` -> `Agent.Loop`
  #     `state.tools` -> `ReactLoop`'s `tools:` option) — consults only
  #     `should_defer?`, so the tool was dropped from it.
  #
  # The result was the worst of both: paid for on every request, and under a
  # native-tool provider (`Anthropic.native_tool_schemas?/0` is true) not
  # callable at all, because a name absent from the tools array is a name the
  # API cannot emit. Nothing re-adds it later either — `tool_search` returns a
  # formatted STRING and touches no state, so the "discoverable mid-turn"
  # promise in `should_defer?`'s comment is not kept for native providers.
  #
  # Setting this to `false` makes the tool consistently deferred: out of the
  # prompt prose, listed by name in the deferred `<system-reminder>` block, and
  # exactly as callable as it was before — which under a native provider is the
  # honest answer, and under a text-parsing provider still works via
  # `tool_search`, since the executor resolves names against the FULL registry
  # (`Registry.execute_unguarded/2`) rather than the advertised array.
  #
  # Measured cost of the contradiction across the five tools that had it:
  # 3,561 bytes / ~890 estimated tokens of static prefix on every request of
  # every session, buying zero callable capability.
  #
  # The reachability hole itself is NOT fixed here — see the note in
  # `Tools.Registry.list_active/0`.
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Read-only regex scan — safe to run concurrently.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  # ── Flat-layout compatibility ─────────────────────────────────────────
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
  def to_classifier_input(%{"path" => p}), do: %{path: p}
  def to_classifier_input(_), do: ""
end
