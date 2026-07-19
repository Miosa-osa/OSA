defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.Tool do
  @moduledoc """
  Structured-layout tool implementation for `task_wait` (P5 join-barrier).

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `TaskWait.Constants` — exported atoms for cross-tool reference
    * `TaskWait.Depth`     — blocking-wait nesting-depth ceiling
    * `TaskWait.Prompt`    — dynamic prompt builder
    * `TaskWait.Handler`   — validate / check_permissions / execute
    * `TaskWait.UI`        — render callbacks for the Rust TUI

  ## Loading semantics
    * `should_defer?` → true  — a niche convergence tool; discovered via
      tool-search rather than kept in every prompt (unlike `delegate`).
    * `always_load?`  → false — same reason.

  ## Execution semantics
    * `concurrency_safe?` → false — the depth-ceiling ETS registry + RunStore
      polling loop are not designed for two concurrent `task_wait` calls from
      the SAME agent to race safely.
    * `read_only?`        → true  — only observes `RunStore`; never mutates
      any agent's state, files, or spawns anything.
    * `destructive?`      → false.
    * `safety/0`          → `:read_only`.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TaskWait.{Constants, Handler, Prompt, UI}

  # ── Identity ───────────────────────────────────────────────────────────

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["join_agents", "wait_for_agents"]

  @impl true
  def search_hint, do: "block until backgrounded agents finish, then return their results"

  # ── Schema & description ───────────────────────────────────────────────

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["agent_ids"],
      "properties" => %{
        "agent_ids" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "agentIds of previously-launched (typically backgrounded) agents to join on. " <>
              "Get these from earlier delegate(background: true) results."
        },
        "require_all" => %{
          "type" => "boolean",
          "description" =>
            "Wait for ALL listed agents to finish (default true). Set false to return as " <>
              "soon as ANY one of them finishes."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" =>
            "Maximum time to block in milliseconds (default 600000 / 10 minutes). Agents " <>
              "still running when the timeout elapses are reported as such, not treated " <>
              "as errors."
        }
      }
    }
  end

  # ── Loading semantics ──────────────────────────────────────────────────

  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ─────────────────────────────────────────────────

  @impl true
  # The depth-ceiling registry + RunStore poll loop are not built to race two
  # concurrent calls from the same agent safely.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  # Only observes RunStore — never mutates agent state, files, or spawns.
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: 8_000

  # ── Flat-layout compatibility ───────────────────────────────────────────

  @impl true
  def safety, do: :read_only

  # ── Two-stage permissioning ─────────────────────────────────────────────

  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ────────────────────────────────────────────────────────────

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ──────────────────────────────────────────────────────────

  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ────────────────────────────────────────────────────

  @impl true
  def to_classifier_input(%{"agent_ids" => ids}), do: %{agent_ids: ids}
  def to_classifier_input(_), do: ""
end
