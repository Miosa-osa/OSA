defmodule OptimalSystemAgent.Tools.Builtins.ProgressNote.Tool do
  @moduledoc """
  Structured-layout entry point for `progress_note`.

  Lets the agent record a decision, step, or todo into this session's durable
  progress ledger (`Agent.ProgressLedger`) — an external markdown file that
  survives every context reset and acts as the coherence anchor for long /
  multi-day runs.

  Per-tool directory layout — declarations only; all logic lives in the sibling
  modules:

    * `ProgressNote.Constants` — exported atoms, limits
    * `ProgressNote.Prompt`    — dynamic prompt
    * `ProgressNote.Handler`   — validate / check_permissions / execute
    * `ProgressNote.UI`        — render callbacks for the Rust TUI

  ## Design decisions

  * `should_defer?` → false — durable note-taking must be available from the
    first turn of any long-running session.
  * `always_load?` → true — same reason.
  * `concurrency_safe?` → false — appends to a single per-session file; serialise
    to avoid interleaved writes.
  * `read_only?` → false — writes to the ledger file.
  * `destructive?` → false — appends/updates; never deletes prior history.
  * `safety/0` → `:write_safe` — writes only to the session's own ledger under
    `~/.osa/sessions/`; non-destructive, no user data at risk.

  ## Schema

  Deliberately a single required `note` string. No `Type.Union` / `oneOf` /
  `anyOf` / raw `format` property — those get rejected by some tool-schema
  validators (e.g. google-antigravity).
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ProgressNote.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: []

  @impl true
  def search_hint,
    do: "record a decision, step, or todo into the durable per-session progress ledger"

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
        "note" => %{
          "type" => "string",
          "description" =>
            "The decision, step, or todo to record. Prefix with 'goal:' to set the session goal."
        }
      },
      "required" => ["note"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Serialised single-file appends — not safe to run concurrently with itself.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: Constants.max_result_size_chars()

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
  def to_classifier_input(%{"note" => note}), do: %{note: note}
  def to_classifier_input(_), do: ""
end
