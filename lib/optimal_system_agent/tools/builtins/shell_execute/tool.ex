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
  # "bash" (9) and "bash_execute" (21) were measured as calls to a tool that
  # does not exist — the model reaching for the name every other harness uses.
  # Aliases are resolved as a fallback in `Tools.Registry` and never appear in
  # the advertised array, so catching these costs zero prefix tokens.
  def aliases, do: ["shell", "run_command", "bash", "bash_execute"]

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
            "Working directory for the command. ALWAYS set this instead of prefixing " <>
              "the command with `cd`. Defaults to the session's current working directory."
        },
        "run_in_background" => %{
          "type" => "boolean",
          "description" =>
            "Optional. When true, run the command as a supervised background " <>
              "process and return a background_id immediately instead of " <>
              "blocking. Poll its output/status with the bash_output tool. " <>
              "Defaults to false (foreground). A foreground command that outlives " <>
              "the wait window is moved to the background automatically rather " <>
              "than being killed."
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
