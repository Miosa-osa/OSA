defmodule OptimalSystemAgent.Tools.Builtins.TaskStop.Tool do
  @moduledoc """
  Structured-layout entry point for `task_stop`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `TaskStop.Constants`  — exported atoms for cross-tool reference
    * `TaskStop.Prompt`     — dynamic prompt with `safe_ref` cross-tool links
    * `TaskStop.Handler`    — validate / check_permissions / execute
    * `TaskStop.UI`         — render callbacks for the Rust TUI

  ## Design decisions

  * `should_defer?` → false — task_stop must always be available so the model
    can cancel a runaway agent on any turn.
  * `always_load?` → true — same reason; the tool is always-on.
  * `concurrency_safe?` → false — Registry lookup + Loop.cancel/1 are not
    atomic; concurrent stop calls for the same agent_id can race.
  * `read_only?` → false — cancellation mutates agent state.
  * `destructive?` → false — cancellation preserves the task list; no data is
    permanently lost (matches task_write's reasoning).
  * `safety/0` → `:write_safe` — mirrors task_write.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TaskStop.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: []

  @impl true
  def search_hint, do: "stop a running background agent task by session ID"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["agent_id"],
      "properties" => %{
        "agent_id" => %{
          "type" => "string",
          "description" => "Session ID of the agent to stop"
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Registry lookup + cancel are not atomic; concurrent calls can race.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Cancellation preserves the task list — no data is permanently lost.
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
  def to_classifier_input(%{"agent_id" => id}), do: %{agent_id: id}
  def to_classifier_input(_), do: ""
end
