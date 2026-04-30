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
  def should_defer?, do: false

  @impl true
  # Always include in prompt — used for navigation alongside file_read.
  def always_load?, do: true

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
