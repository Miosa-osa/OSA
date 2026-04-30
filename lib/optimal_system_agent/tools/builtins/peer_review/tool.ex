defmodule OptimalSystemAgent.Tools.Builtins.PeerReview.Tool do
  @moduledoc """
  Structured-layout entry point for `peer_review`.

  Per-tool directory layout — declarations only; logic lives in sibling modules:
    * `PeerReview.Constants` — exported atoms for cross-tool reference
    * `PeerReview.Prompt`    — dynamic prompt builder
    * `PeerReview.Handler`   — validate / check_permissions / execute
    * `PeerReview.UI`        — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.PeerReview.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def search_hint, do: "request or submit a peer review on a work artifact"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Constants.actions(),
          "description" =>
            "request: submit artifact for review, check: poll review status, submit: post verdict"
        },
        "artifact" => %{
          "type" => "string",
          "description" => "File path or inline content to review (for 'request' action)."
        },
        "reviewer_agent" => %{
          "type" => "string",
          "description" => "Agent ID of the reviewer (for 'request' action)."
        },
        "artifact_id" => %{
          "type" => "string",
          "description" =>
            "Artifact ID returned by a prior 'request' call (for 'check'/'submit')."
        },
        "verdict" => %{
          "type" => "string",
          "enum" => Constants.verdicts(),
          "description" => "Review verdict (for 'submit' action)."
        },
        "comments" => %{
          "type" => "string",
          "description" => "Review comments or summary (for 'submit' action)."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  # ── Flat-layout compatibility ─────────────────────────────────────────
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
  def to_classifier_input(%{"action" => a} = input),
    do: %{action: a, artifact_id: input["artifact_id"]}

  def to_classifier_input(_), do: ""
end
