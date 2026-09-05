defmodule OptimalSystemAgent.Tools.Builtins.Goal.UpdateTool do
  @moduledoc """
  `update_goal` — model-controlled completion claims, blockers, abandonment,
  and structured human handoff. Decision fields cannot rewrite the objective;
  approval/rejection are exclusively user commands, not model statuses.

  Ported from Codex's `update_goal` (`codex-rs/ext/goal/src/spec.rs` and
  `tool.rs`). Two properties of that design are carried over exactly:

    * Decision metadata names a pending question; there is no path from the
      model to the objective. Codex's handler builds its update with
      `objective: None` hardcoded.

    * Everything outside the accepted status set is refused with Codex's own
      message — pause and resume belong to the user.

  One status is added on purpose. Codex accepts only `complete` and `blocked`,
  which between them leave an agent whose work legitimately changed direction
  with no reachable exit: `complete` is adjudicated by a panel, `blocked` needs
  three consecutive TOP-LEVEL turns (unreachable inside one unattended
  autonomous turn), and clearing the goal is the user's. `abandoned` is that
  exit — terminal, permanently recorded, and budget-carrying, so it redirects a
  run without refilling it. See `GoalTracker.abandon/1`.

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
        "question" => %{
          "type" => "string",
          "description" => "For awaiting_user: the specific decision only the user can make."
        },
        "criterion" => %{
          "type" => "string",
          "description" =>
            "For awaiting_user: the existing user-grounded requirement needing input; never invent an approval gate."
        },
        "work_summary" => %{
          "type" => "string",
          "description" =>
            "For awaiting_user: completed work and any remaining machine-verifiable work. Waiting is not completion."
        },
        "artifact" => %{
          "type" => "string",
          "description" =>
            "For awaiting_user: exact artifact/version or decision scope the user is reviewing."
        },
        "status" => %{
          "type" => "string",
          "enum" => Constants.model_statuses(),
          "description" =>
            "Required. Set to `complete` only when the objective is achieved and no required " <>
              "work remains; this schedules an independent review panel rather than ending " <>
              "the goal. Set to `blocked` only after the same blocking condition has recurred " <>
              "for at least three consecutive goal turns and you are at an impasse. After a " <>
              "previously blocked goal is resumed, the resumed run starts a fresh blocked " <>
              "audit. Set to `abandoned` only when this objective is no longer the work at " <>
              "all — the direction changed, not the difficulty; it ends the goal permanently, " <>
              "records it as abandoned, and lets a new goal be anchored, but the successor " <>
              "inherits the turns and verification rounds already spent. Use awaiting_user when " <>
              "progress requires a specific human decision; provide question, criterion, work_summary " <>
              "and artifact. This stops autonomous work without declaring completion. Never invent " <>
              "approval requirements, and never use repeated busywork as evidence of progress."
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
