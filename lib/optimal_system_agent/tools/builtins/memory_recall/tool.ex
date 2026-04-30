defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall.Tool do
  @moduledoc """
  Structured-layout tool implementation for `memory_recall`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `MemoryRecall.Constants`  — exported atoms for cross-tool reference
    * `MemoryRecall.Prompt`     — dynamic prompt builder
    * `MemoryRecall.Handler`    — validate / check_permissions / execute
    * `MemoryRecall.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.MemoryRecall.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["mem_recall", "mem_search", "memory_search"]

  @impl true
  def search_hint, do: "search and retrieve memories saved with memory_save"

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
          "description" => "Search query — keywords or natural language"
        },
        "category" => %{
          "type" => "string",
          "description" => "Filter by category",
          "enum" => Constants.valid_categories()
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results (default #{Constants.default_limit()})"
        }
      },
      "required" => ["query"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # memory_recall must always be in the prompt — the model needs it
  # at session start to recover saved context.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Read-only — safe to execute concurrently.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

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
