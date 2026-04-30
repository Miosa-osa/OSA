defmodule OptimalSystemAgent.Tools.Builtins.CreateSkill.Tool do
  @moduledoc """
  Structured-layout tool implementation for `create_skill`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `CreateSkill.Constants`  — exported atoms for cross-tool reference
    * `CreateSkill.Prompt`     — dynamic prompt builder
    * `CreateSkill.Handler`    — validate / execute
    * `CreateSkill.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.CreateSkill.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["skill_create", "new_skill"]

  @impl true
  def search_hint, do: "create a reusable skill document for future tasks"

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
        "name" => %{
          "type" => "string",
          "description" => "Kebab-case skill name (e.g. 'express-api-testing')"
        },
        "description" => %{
          "type" => "string",
          "description" => "What this skill helps with"
        },
        "trigger" => %{
          "type" => "string",
          "description" => "Keywords or regex for when to activate (e.g. 'express|rest api|jest')"
        },
        "instructions" => %{
          "type" => "string",
          "description" => "Step-by-step instructions for the skill"
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tags for categorization"
        }
      },
      "required" => ["name", "description", "trigger", "instructions"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :write_safe

  # ── Two-stage permissioning ───────────────────────────────────────────
  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  # ── Execution ─────────────────────────────────────────────────────────
  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ─────────────────────────────────────────────────────────
  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ──────────────────────────────────────────────────
  @impl true
  def to_classifier_input(%{"name" => n, "trigger" => t}), do: %{skill_name: n, trigger: t}
  def to_classifier_input(_), do: ""
end
