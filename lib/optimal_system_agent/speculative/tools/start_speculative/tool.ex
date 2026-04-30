defmodule OptimalSystemAgent.Speculative.Tools.StartSpeculative.Tool do
  @moduledoc """
  Structured-layout tool implementation for `start_speculative`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `StartSpeculative.Constants`  — exported atoms for cross-tool reference
    * `StartSpeculative.Prompt`     — dynamic prompt builder
    * `StartSpeculative.Handler`    — validate / execute
    * `StartSpeculative.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Speculative.Tools.StartSpeculative.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["speculative_start", "work_ahead"]

  @impl true
  def search_hint, do: "begin speculative work ahead on a predicted next task"

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
        "predicted_next_task" => %{
          "type" => "string",
          "description" =>
            "Description of the task predicted to be assigned next. " <>
              "Be specific — this drives what gets worked on."
        },
        "assumptions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "List of conditions that must still be true when the real task arrives " <>
              "for this work to be valid. E.g. 'user_intent_unchanged', 'no conflicting PR merged'.",
          "minItems" => 1
        },
        "agent_id" => %{
          "type" => "string",
          "description" =>
            "Identifier of the agent performing the speculative work. " <>
              "Optional — defaults to 'unknown'."
        }
      },
      "required" => ["predicted_next_task", "assumptions"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :subagent

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
  def to_classifier_input(%{"predicted_next_task" => t}), do: %{predicted_next_task: t}
  def to_classifier_input(_), do: ""
end
