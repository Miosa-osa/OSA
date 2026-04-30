defmodule OptimalSystemAgent.Tools.Builtins.ListSkills.Tool do
  @moduledoc """
  Structured-layout tool implementation for `list_skills`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `ListSkills.Constants`  — exported atoms for cross-tool reference
    * `ListSkills.Prompt`     — dynamic prompt builder
    * `ListSkills.Handler`    — validate / execute
    * `ListSkills.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ListSkills.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["skills_list", "show_skills"]

  @impl true
  def search_hint, do: "list all available reusable skills"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Only load when the model is curious about available skills — not on every turn.
  def should_defer?, do: false

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
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

  # ── Execution ─────────────────────────────────────────────────────────
  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ─────────────────────────────────────────────────────────
  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ──────────────────────────────────────────────────
  @impl true
  def to_classifier_input(_input), do: ""
end
