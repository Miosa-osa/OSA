defmodule OptimalSystemAgent.Tools.Builtins.MemorySave.Tool do
  @moduledoc """
  Structured-layout tool implementation for `memory_save`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `MemorySave.Constants`  — exported atoms for cross-tool reference
    * `MemorySave.Prompt`     — dynamic prompt builder
    * `MemorySave.Handler`    — validate / check_permissions / execute
    * `MemorySave.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.MemorySave.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["mem_save", "remember"]

  @impl true
  def search_hint, do: "save facts, decisions, and preferences to persistent memory"

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
        "content" => %{
          "type" => "string",
          "description" => "The memory to save. Be specific and concise."
        },
        "category" => %{
          "type" => "string",
          "description" =>
            "Category: decision, preference, pattern, lesson, context, or project. Auto-detected if omitted.",
          "enum" => Constants.valid_categories()
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Optional tags for search"
        }
      },
      "required" => ["content"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # memory_save must always be in the prompt — the model cannot defer
  # saving critical context to a future session.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Writes to shared memory store — not concurrency-safe.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Saves are additive — they do not overwrite or delete existing memories.
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def safety, do: :write_safe

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
  def to_classifier_input(%{"content" => c}), do: %{content: c}
  def to_classifier_input(_), do: ""
end
