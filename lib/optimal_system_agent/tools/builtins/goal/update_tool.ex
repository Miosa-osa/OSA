defmodule OptimalSystemAgent.Tools.Builtins.Goal.UpdateTool do
  @moduledoc """
  `update_goal` — the only status the model may move a goal to, and the only
  two values it may move it to.

  Ported from Codex's `update_goal` (`codex-rs/ext/goal/src/spec.rs` and
  `tool.rs`). Two properties of that design are carried over exactly:

    * The parameter set is `status` and nothing else. There is no path from the
      model to the objective. Codex's handler builds its update with
      `objective: None` hardcoded.

    * `status` accepts only `complete` and `blocked`. Everything else is refused
      with Codex's own message — pause and resume belong to the user.

  One property is deliberately stronger here. In Codex, `complete` writes
  `complete` to the database and the goal is over; the only thing between a
  self-authored goal and a self-declared success is the continuation prompt's
  wording. Here `complete` schedules the skeptic panel instead, which is
  grok-build's arrangement (`UpdateGoalAck::CompletedWithoutClassifier` — the
  model's flag completes the goal only when the classifier is switched off).
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Goal.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.update_tool_name()

  @impl true
  def aliases, do: ["goal_update"]

  @impl true
  def search_hint, do: "mark the active goal complete or blocked"

  @impl true
  def description, do: Prompt.update_goal_short()

  @impl true
  def prompt(opts), do: Prompt.update_goal(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "status" => %{
          "type" => "string",
          "enum" => Constants.model_statuses(),
          "description" =>
            "Required. Set to `complete` only when the objective is achieved and no required " <>
              "work remains; this schedules an independent review panel rather than ending " <>
              "the goal. Set to `blocked` only after the same blocking condition has recurred " <>
              "for at least three consecutive goal turns and you are at an impasse. After a " <>
              "previously blocked goal is resumed, the resumed run starts a fresh blocked audit."
        }
      },
      "required" => ["status"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: Constants.max_result_size_chars()

  @impl true
  def safety, do: :write_safe

  # ── Pipeline ──────────────────────────────────────────────────────────
  @impl true
  def validate_input(input, ctx), do: Handler.validate_update(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  @impl true
  def execute(input, ctx), do: Handler.execute_update(input, ctx)

  @impl true
  def render(stage, payload, opts), do: UI.render_update(stage, payload, opts)

  @impl true
  def to_classifier_input(%{"status" => s}), do: %{status: s}
  def to_classifier_input(_), do: ""
end
