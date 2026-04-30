defmodule OptimalSystemAgent.Verification.Tools.VerifyLoop.Tool do
  @moduledoc """
  Structured-layout tool implementation for `verify_loop`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `VerifyLoop.Constants`  — exported atoms for cross-tool reference
    * `VerifyLoop.Prompt`     — dynamic prompt builder
    * `VerifyLoop.Handler`    — validate / execute
    * `VerifyLoop.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Verification.Tools.VerifyLoop.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["verification_loop", "run_verify"]

  @impl true
  def search_hint, do: "spawn autonomous write-test-fix verification loop"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["test_command"],
      "properties" => %{
        "test_command" => %{
          "type" => "string",
          "description" =>
            "Shell command to run as the verification gate. " <>
              "Exit code 0 = pass, non-zero = fail. " <>
              "Examples: 'mix test', 'npm test', 'pytest', 'go test ./...'."
        },
        "max_iterations" => %{
          "type" => "integer",
          "description" =>
            "Maximum number of fail/fix/re-test cycles before escalating to human. " <>
              "Default: #{Constants.default_max_iterations()}. " <>
              "Must be between #{Constants.min_iterations()} and #{Constants.max_iterations()}.",
          "default" => Constants.default_max_iterations(),
          "minimum" => Constants.min_iterations(),
          "maximum" => Constants.max_iterations()
        },
        "task_id" => %{
          "type" => "string",
          "description" =>
            "Identifier of the task being verified. " <>
              "Defaults to the current session ID if omitted."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
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

  # ── Execution ─────────────────────────────────────────────────────────
  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ─────────────────────────────────────────────────────────
  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ──────────────────────────────────────────────────
  @impl true
  def to_classifier_input(%{"test_command" => cmd}), do: %{test_command: cmd}
  def to_classifier_input(_), do: ""
end
