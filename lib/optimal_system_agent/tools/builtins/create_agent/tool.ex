defmodule OptimalSystemAgent.Tools.Builtins.CreateAgent.Tool do
  @moduledoc """
  Structured-layout tool: create a new agent role on the fly.

  Per-tool directory layout — declarations only; all logic lives in siblings:

    * `CreateAgent.Constants`  — exported atoms; referenced by `ListAgents.Prompt`
    * `CreateAgent.Prompt`     — dynamic prompt referencing `list_agents` and `delegate`
    * `CreateAgent.Handler`    — validate / check_permissions / execute
    * `CreateAgent.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.CreateAgent.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["define_agent", "new_agent"]

  @impl true
  def search_hint, do: "create a new specialized agent role for delegation"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["name", "instructions"],
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" =>
            "Agent role name (lowercase, hyphenated). e.g., 'data-analyst', 'api-tester'"
        },
        "description" => %{
          "type" => "string",
          "description" => "One-line description of what this agent specialises in."
        },
        "tier" => %{
          "type" => "string",
          "enum" => Constants.valid_tiers(),
          "description" => "Model tier. Default: specialist."
        },
        "instructions" => %{
          "type" => "string",
          "description" =>
            "Full system prompt for the agent. Describe its approach, output format, and boundaries."
        },
        "tools_blocked" => %{
          "type" => "string",
          "description" =>
            "Comma-separated tools to block. e.g., 'file_write,shell_execute' for read-only agents."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Deferred — the model shouldn't need this unless it's explicitly building a new role.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # Writes to ~/.osa/agents/ and mutates the AgentRegistry — not concurrent-safe.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

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
  def to_classifier_input(%{"name" => n}), do: %{name: n}
  def to_classifier_input(_), do: ""
end
