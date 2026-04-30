defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Tool do
  @moduledoc """
  Structured-layout shell_execute tool implementation.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `ShellExecute.Constants`  — exported atoms and compiled patterns
    * `ShellExecute.Prompt`     — dynamic prompt builder
    * `ShellExecute.Handler`    — validate / check_permissions / execute
    * `ShellExecute.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["shell", "run_command"]

  @impl true
  def search_hint, do: "execute shell commands: git, mix, npm, cargo, docker, make"

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
        "command" => %{"type" => "string", "description" => "Shell command to execute"},
        "cwd" => %{
          "type" => "string",
          "description" =>
            "Working directory for the command. Optional; defaults to ~/.osa/workspace."
        }
      },
      "required" => ["command"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # shell_execute is on the hot path — always include in prompt.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # NOT concurrency-safe — commands can cd, mutate env, write files.
  # Conservative: always false, matching flat-layout concurrent?/0 → false.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Shells can do anything — destructive by definition.
  def destructive?(_input, _ctx), do: true

  @impl true
  # Talks directly to the OS — fully open-world.
  def open_world?(_input, _ctx), do: true

  @impl true
  # Long-running shells should be cancelable, not blocking.
  def interrupt_behavior, do: :cancel

  @impl true
  def max_result_size_chars, do: 30_000

  # ── Flat-layout compatibility ──────────────────────────────────────────────────
  @impl true
  def safety, do: :terminal

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
  def to_classifier_input(%{"command" => cmd}), do: %{command: cmd}
  def to_classifier_input(_), do: ""
end
