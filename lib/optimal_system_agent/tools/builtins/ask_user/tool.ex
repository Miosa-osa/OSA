defmodule OptimalSystemAgent.Tools.Builtins.AskUser.Tool do
  @moduledoc """
  Structured-layout tool implementation for `ask_user`.

  Asks the user a question mid-task and blocks until the user responds.
  All logic lives in the sibling modules:

    * `AskUser.Constants`  — exported atoms for cross-tool reference
    * `AskUser.Prompt`     — dynamic prompt builder
    * `AskUser.Handler`    — validate / check_permissions / execute
    * `AskUser.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.AskUser.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["ask", "question"]

  @impl true
  def search_hint, do: "ask the user a question and wait for their response"

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
        "question" => %{
          "type" => "string",
          "description" => "The question, as a single short sentence"
        },
        "options" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "2-4 exclusive choices, recommended first. No \"Other\"."
        },
        "header" => %{
          "type" => "string",
          "description" => "Optional category chip, at most 12 characters"
        }
      },
      "required" => ["question"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # ask_user must always be available — the agent can need it at any point.
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # ask_user blocks the calling process; do not parallelise with other tools.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  # Does not modify state — only reads user input.
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  # Block — the agent loop must wait for the user's answer.

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
  def to_classifier_input(%{"question" => q}), do: %{question: q}
  def to_classifier_input(_), do: ""
end
