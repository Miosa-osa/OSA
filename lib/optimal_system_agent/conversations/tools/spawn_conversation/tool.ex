defmodule OptimalSystemAgent.Conversations.Tools.SpawnConversation.Tool do
  @moduledoc """
  Structured-layout tool implementation for `spawn_conversation`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `SpawnConversation.Constants`  — exported atoms for cross-tool reference
    * `SpawnConversation.Prompt`     — dynamic prompt builder
    * `SpawnConversation.Handler`    — validate / execute
    * `SpawnConversation.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Conversations.Tools.SpawnConversation.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["conversation", "debate", "multi_agent_conversation"]

  @impl true
  def search_hint, do: "spawn a structured multi-agent conversation or debate"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["type", "topic", "participant_roles"],
      "properties" => %{
        "type" => %{
          "type" => "string",
          "enum" => Constants.valid_types(),
          "description" => "The conversation format to use."
        },
        "topic" => %{
          "type" => "string",
          "description" => "The subject, question, or proposal the conversation should address."
        },
        "participant_roles" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "List of participant roles. Use predefined keys " <>
              "(#{Enum.join(Constants.predefined_roles(), ", ")}) or custom role strings.",
          "minItems" => 2,
          "maxItems" => 8
        },
        "max_turns" => %{
          "type" => "integer",
          "description" => "Maximum number of turns (default: #{Constants.default_max_turns()}).",
          "minimum" => 2,
          "maximum" => 50
        },
        "strategy" => %{
          "type" => "string",
          "enum" => Constants.valid_strategies(),
          "description" => "Turn-taking strategy (default: round_robin)."
        },
        "facilitator_role" => %{
          "type" => "string",
          "description" =>
            "Role for the facilitator when strategy=facilitator. Defaults to pragmatist."
        }
      }
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
  def to_classifier_input(%{"topic" => t, "type" => type}), do: %{topic: t, type: type}
  def to_classifier_input(_), do: ""
end
