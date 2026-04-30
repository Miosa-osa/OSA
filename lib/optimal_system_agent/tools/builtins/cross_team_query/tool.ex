defmodule OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.Tool do
  @moduledoc """
  Structured-layout entry point for `cross_team_query`.

  Per-tool directory layout — declarations only; logic lives in sibling modules:
    * `CrossTeamQuery.Constants` — exported atoms for cross-tool reference
    * `CrossTeamQuery.Prompt`    — dynamic prompt builder
    * `CrossTeamQuery.Handler`   — validate / check_permissions / execute
    * `CrossTeamQuery.UI`        — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.CrossTeamQuery.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def search_hint, do: "send a read-only question to another team and get a response"

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
            "ask: send question, poll: check answer, answer: reply to a query, list: see pending queries"
        },
        "target_team" => %{
          "type" => "string",
          "description" => "Team ID to ask (required for 'ask')."
        },
        "question" => %{
          "type" => "string",
          "description" => "Question to send (required for 'ask')."
        },
        "query_id" => %{
          "type" => "string",
          "description" => "Query ID from a prior 'ask' call (required for 'poll'/'answer')."
        },
        "answer" => %{
          "type" => "string",
          "description" => "Answer to the query (required for 'answer')."
        },
        "team_id" => %{
          "type" => "string",
          "description" => "Your team ID (used for 'list')."
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
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

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
  def to_classifier_input(%{"action" => a} = input),
    do: %{action: a, target_team: input["target_team"], query_id: input["query_id"]}

  def to_classifier_input(_), do: ""
end
