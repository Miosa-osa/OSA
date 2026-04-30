defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Tool do
  @moduledoc """
  Structured-layout entry point for `mixture_of_agents`.

  Per-tool directory layout — declarations only; logic lives in sibling modules:
    * `MixtureOfAgents.Constants` — exported atoms for cross-tool reference
    * `MixtureOfAgents.Prompt`    — dynamic prompt builder (refs `delegate`)
    * `MixtureOfAgents.Handler`   — validate / check_permissions / execute
    * `MixtureOfAgents.UI`        — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def search_hint,
    do: "fan out a query to multiple LLM providers and synthesize the best response"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["query"],
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The question or problem to send to multiple models"
        },
        "providers" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "List of providers to query (e.g. [\"anthropic\", \"openai\", \"groq\"]). " <>
              "Defaults to all available."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  # ── Execution semantics ───────────────────────────────────────────────
  # MoA dispatches provider calls in parallel internally via Task.Supervisor,
  # so it is safe to run multiple MoA calls concurrently at the tool level.
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :subagent

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
  def to_classifier_input(%{"query" => q} = input),
    do: %{query_preview: String.slice(q, 0, 80), providers: input["providers"]}

  def to_classifier_input(_), do: ""
end
