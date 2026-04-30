defmodule OptimalSystemAgent.Tools.Builtins.TeamDelete.Tool do
  @moduledoc """
  Structured-layout tool: dissolve an agent team and reclaim its resources.

  Per-tool directory layout — declarations only; all logic lives in siblings:

    * `TeamDelete.Constants`  — exported atoms for cross-tool reference
    * `TeamDelete.Prompt`     — dynamic description injected at runtime
    * `TeamDelete.Handler`    — validate / check_permissions / execute
    * `TeamDelete.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TeamDelete.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["delete_team", "dissolve_team"]

  @impl true
  def search_hint, do: "dissolve an agent team and terminate all its processes"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["team_id"],
      "properties" => %{
        "team_id" => %{
          "type" => "string",
          "description" =>
            "The team_id returned by team_create. " <>
              "All agents, sub-teams, and ETS state are permanently destroyed."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # Mutates the shared team registry — not concurrent-safe.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Terminates running processes and destroys ETS state — destructive.
  def destructive?(_input, _ctx), do: true

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def interrupt_behavior, do: :block

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
  def to_classifier_input(%{"team_id" => id}), do: %{team_id: id}
  def to_classifier_input(_), do: ""
end
