defmodule OptimalSystemAgent.Tools.Builtins.SessionSearch.Tool do
  @moduledoc """
  Structured-layout entry point for `session_search`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `SessionSearch.Constants`  — exported atoms, limits, preview size
    * `SessionSearch.Prompt`     — dynamic prompt
    * `SessionSearch.Handler`    — validate / check_permissions / execute
    * `SessionSearch.UI`         — render callbacks for the Rust TUI

  ## Design decisions

  * `should_defer?` → false — session_search is always-on (memory recall must
    be available from the first turn of any session).
  * `always_load?` → true — same reason.
  * `concurrency_safe?` → true — read-only FTS + Memory queries; no shared
    mutable state is modified.
  * `read_only?` → true — pure search; no writes.
  * `destructive?` → false — no data is modified or deleted.
  * `max_result_size_chars/0` → 50_000 — FTS results can be large; cap prevents
    context overflow while still allowing meaningful result sets.
  * `safety/0` → `:read_only`.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.SessionSearch.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: []

  @impl true
  def search_hint, do: "search past conversation sessions for messages matching a query"

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
        "query" => %{
          "type" => "string",
          "description" => "Search query"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results (default #{Constants.default_limit()})"
        }
      },
      "required" => ["query"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Read-only FTS + Memory queries — safe to run concurrently.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: Constants.max_result_size_chars()

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
  def to_classifier_input(%{"query" => q}), do: %{query: q}
  def to_classifier_input(_), do: ""
end
