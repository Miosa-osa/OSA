defmodule OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.Tool do
  @moduledoc """
  Structured-layout entry point for `peer_negotiate_task`.

  Per-tool directory layout — declarations only; logic lives in sibling modules:
    * `PeerNegotiateTask.Constants` — exported atoms for cross-tool reference
    * `PeerNegotiateTask.Prompt`    — dynamic prompt builder
    * `PeerNegotiateTask.Handler`   — validate / check_permissions / execute
    * `PeerNegotiateTask.UI`        — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def search_hint, do: "contest, redirect, or accept a task assignment"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action", "negotiation_id"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Constants.actions(),
          "description" =>
            "counter: propose alternate agent, accept: take the task, reject: decline, status: check state"
        },
        "negotiation_id" => %{
          "type" => "string",
          "description" => "Negotiation ID from the task assignment notification."
        },
        "counter_agent" => %{
          "type" => "string",
          "description" => "Agent ID of the suggested replacement (required for 'counter')."
        },
        "reason" => %{
          "type" => "string",
          "description" => "Justification for counter or rejection."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  # ── Execution semantics ───────────────────────────────────────────────
  # Negotiations must serialize — concurrent accept/reject on the same
  # negotiation_id would cause split-brain assignment.
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

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
  def to_classifier_input(%{"action" => a, "negotiation_id" => nid}),
    do: %{action: a, negotiation_id: nid}

  def to_classifier_input(_), do: ""
end
