defmodule OptimalSystemAgent.Tools.Builtins.ListAgents.Tool do
  @moduledoc """
  Structured-layout tool: list available agent roles.

  Per-tool directory layout — declarations only; all logic lives in siblings:

    * `ListAgents.Constants`  — exported atoms for cross-tool reference
    * `ListAgents.Prompt`     — dynamic prompt referencing `create_agent` and `delegate`
    * `ListAgents.Handler`    — validate / check_permissions / execute
    * `ListAgents.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ListAgents.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["agents", "list_agent_roles"]

  @impl true
  def search_hint, do: "list available agent roles and their capabilities"

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
        "role" => %{
          "type" => "string",
          "description" =>
            "Optional: get full details for a specific role. Omit to list all agents."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # The model often needs the roster before deciding how to delegate.
  def always_load?, do: true

  @impl true
  def should_defer?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :read_only

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
  def to_classifier_input(%{"role" => r}), do: %{role: r}
  def to_classifier_input(_), do: ""
end
