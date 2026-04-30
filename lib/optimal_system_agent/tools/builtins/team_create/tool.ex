defmodule OptimalSystemAgent.Tools.Builtins.TeamCreate.Tool do
  @moduledoc """
  Structured-layout tool: spawn a new agent team for parallel goal pursuit.

  Per-tool directory layout — declarations only; all logic lives in siblings:

    * `TeamCreate.Constants`  — exported atoms for cross-tool reference
    * `TeamCreate.Prompt`     — dynamic description injected at runtime
    * `TeamCreate.Handler`    — validate / check_permissions / execute
    * `TeamCreate.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TeamCreate.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["create_team", "spawn_team"]

  @impl true
  def search_hint, do: "spawn a new agent team to work on a shared goal"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["name", "members"],
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" =>
            "Human-readable team name (max #{Constants.max_name_length()} chars)"
        },
        "members" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "List of agent role names to spawn in the team (max #{Constants.max_members()}). " <>
              "Use list_agents to discover valid roles."
        },
        "goal" => %{
          "type" => "string",
          "description" => "Optional natural-language objective for the team"
        },
        "budget_usd" => %{
          "type" => "number",
          "description" => "USD budget ceiling for the team (default 1.0)"
        },
        "parent_id" => %{
          "type" => "string",
          "description" => "team_id of an existing team to nest this one under (max depth 3)"
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Deferred — team orchestration is a background concern; don't include by default.
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
  # Creates new processes; not destructive.
  def destructive?(_input, _ctx), do: false

  @impl true
  # Spawns external subagent processes — open world.
  def open_world?(_input, _ctx), do: true

  @impl true
  def interrupt_behavior, do: :block

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  # Safety: :subagent signals the permission layer this tool spawns subagents.
  # We map it to :write_safe here because :subagent is not in the legacy
  # safety/0 enum — the structured read_only?/destructive? callbacks carry
  # the correct semantics for structured-layout callers.
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
  def to_classifier_input(%{"name" => n, "members" => m}),
    do: %{name: n, member_count: length(m)}

  def to_classifier_input(_), do: ""
end
