defmodule OptimalSystemAgent.Tools.Builtins.Goal.CreateTool do
  @moduledoc """
  `create_goal` — the agent authors its own cross-turn objective and the
  acceptance criteria it will be judged against.

  Ported from Codex's `create_goal` (`codex-rs/ext/goal/src/spec.rs`), with
  Codex's `token_budget` parameter replaced by `acceptance_criteria`. Codex's
  goal carries no criteria at all — its `thread_goals` table has a single
  `objective TEXT` column — so the criteria half of this is grok-build's
  `goal_planner_prompt.md`, which is the other reference harness's answer to the
  same problem.

  ## Schema

  Two plain strings plus an optional third. No `oneOf`/`anyOf`/`Type.Union` and
  no raw `format` property — those are rejected by some tool-schema validators.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Goal.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.create_tool_name()

  @impl true
  def aliases, do: ["set_goal", "goal_create"]

  @impl true
  def search_hint,
    do: "anchor a persistent multi-turn goal with the acceptance criteria it is judged against"

  @impl true
  def description, do: Prompt.create_goal_short()

  @impl true
  def prompt(opts), do: Prompt.create_goal(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "objective" => %{
          "type" => "string",
          "description" =>
            "Required. One concrete sentence naming the end state that must become true. " <>
              "Anchored to what was literally asked — neither narrowed to the easy part " <>
              "nor inflated with unrequested scope. Frozen once set."
        },
        "acceptance_criteria" => %{
          "type" => "string",
          "description" =>
            "The gating set every one of which must hold to pass. Aim for 3-5 numbered, " <>
              "outcome-based criteria, one observable outcome each, each naming the evidence " <>
              "that would prove it. Constrain the WHAT, not the HOW. Frozen once set."
        },
        "constraints" => %{
          "type" => "string",
          "description" => "Optional hard constraints the work must respect. Frozen once set."
        }
      },
      "required" => ["objective"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  # A goal that can only be anchored after a tool search is a goal that will not
  # be anchored on the turn it is needed.
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
  def validate_input(input, ctx), do: Handler.validate_create(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  @impl true
  def execute(input, ctx), do: Handler.execute_create(input, ctx)

  @impl true
  def render(stage, payload, opts), do: UI.render_create(stage, payload, opts)

  @impl true
  def to_classifier_input(%{"objective" => o}), do: %{objective: o}
  def to_classifier_input(_), do: ""
end
