defmodule OptimalSystemAgent.Tools.Builtins.REPL.Tool do
  @moduledoc """
  Structured-layout tool implementation for `repl`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `REPL.Constants`  — exported atoms for cross-tool reference
    * `REPL.Prompt`     — dynamic prompt builder
    * `REPL.Handler`    — validate / check_permissions / execute
    * `REPL.UI`         — render callbacks for the Rust TUI

  ## Execution semantics
  `should_defer? true` — REPL execution can be long-running. The orchestrator
  defers it to a background task rather than blocking the streaming response.
  `concurrency_safe? false` — session state is mutable across executions.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.REPL.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["run_code", "execute_code"]

  @impl true
  def search_hint, do: "execute code snippets in Python, Elixir, or Node.js REPL"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["code"],
      "properties" => %{
        "code" => %{
          "type" => "string",
          "description" => "Code to execute in the REPL"
        },
        "language" => %{
          "type" => "string",
          "enum" => ["python", "elixir", "node"],
          "description" => "Language runtime (default: python)"
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Reuse a named session for state persistence (default: auto)"
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # REPL calls can be long-running; defer to avoid blocking streaming response.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Session state is mutated across calls — not safe to run concurrently.
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
  def to_classifier_input(%{"code" => c, "language" => lang}), do: %{code: c, language: lang}
  def to_classifier_input(%{"code" => c}), do: %{code: c, language: "python"}
  def to_classifier_input(_), do: ""
end
