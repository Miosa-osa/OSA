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
        "command" => %{
          "type" => "string",
          "description" =>
            "Shell command to execute. Prefer absolute literal paths, quoted if they " <>
              "contain spaces. Permission is decided per SEGMENT: the line is split at " <>
              "`|`, `&&`, `||`, `;`, `&` (not inside quotes or `$(...)`) and each " <>
              "segment's first word classified. ONE risky segment — rm, sudo, chmod, " <>
              "chown, kill, mount, systemctl, nc, shutdown, piping into a shell, " <>
              "redirecting into system directories, `git reset --hard`, `git clean -f`, " <>
              "force-push, or a file-mutating command reaching outside the working " <>
              "directory — sends the WHOLE line to approval, and it is approved or " <>
              "refused AS A WHOLE. So keep an unrelated risky step out of a line you " <>
              "want waved through, and send UNRELATED commands as separate calls in one " <>
              "turn rather than joining them with `;`, which merges their exit codes " <>
              "into one approval. A heredoc (`<<`) or command substitution (`$(`, " <>
              "backticks) can never be saved as an always-allow rule and will prompt " <>
              "every time; favour one self-contained `-c` script over several heredocs. " <>
              "Bound an open-ended discovery scan (`-maxdepth`, `-d 1`); on a non-zero " <>
              "exit CHANGE the command rather than retrying a near-identical variant."
        },
        "cwd" => %{
          "type" => "string",
          "description" =>
            "Working directory for the command. ALWAYS set this instead of prefixing " <>
              "the command with `cd`. Defaults to the session's current working directory."
        },
        "run_in_background" => %{
          "type" => "boolean",
          "description" =>
            "Optional, defaults to false (foreground). Set true UP FRONT for a long " <>
              "job whose result you will come back for: the call returns a " <>
              "background_id immediately. Collect the result with a SINGLE bash_output " <>
              "call using `wait_ms` — never poll it in a loop and never sleep between " <>
              "calls. A background process is killed when the session ends, so it is " <>
              "the wrong tool for a server that must outlive the task."
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
