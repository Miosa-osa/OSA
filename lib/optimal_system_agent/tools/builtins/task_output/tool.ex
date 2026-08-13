defmodule OptimalSystemAgent.Tools.Builtins.TaskOutput.Tool do
  @moduledoc """
  Structured-layout entry point for `task_output`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `TaskOutput.Constants`  — exported atoms for cross-tool reference
    * `TaskOutput.Prompt`     — dynamic prompt with `safe_ref` cross-tool links
    * `TaskOutput.Handler`    — validate / check_permissions / execute
    * `TaskOutput.UI`         — render callbacks for the Rust TUI

  ## Design decisions

  * `should_defer?` → false — task_output must always be available so the model
    can inspect any agent on any turn without waiting for a deferred load.
  * `always_load?` → true — same reason; always-on.
  * `concurrency_safe?` → true — read-only Registry lookup + state inspection;
    no shared mutable state is modified.
  * `read_only?` → true — inspects agent state; does not modify anything.
  * `destructive?` → false — no data is modified or deleted.
  * `safety/0` → `:read_only` — matches the read-only semantics above.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TaskOutput.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: []

  @impl true
  def search_hint, do: "get output and status of a running or completed agent task"

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
          "description" => "Session ID of the agent to check"
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # DEFERRED, overriding an earlier deliberate `false`.
  #
  # The original reasoning was that this should be usable from turn 1. That is
  # a testable claim and the measurement contradicts it: across 15 SWE-bench Pro
  # transcripts covering 863 turns and 963 tool calls, this tool was invoked
  # ZERO times while its schema was re-sent on every single request.
  #
  # Reason it is safe to defer: background-task management, meaningless until a task has been spawned.
  #
  # Nothing is lost — deferred tools stay registered and discoverable mid-turn
  # through `tool_search`. What changes is that the model is no longer billed
  # for a description it never reads.
  #
  # Reopen this if a workload appears where it IS called early. The measurement
  # is from coding tasks; it is not a claim about every workload.
  def should_defer?, do: true

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Read-only Registry lookup — safe to run concurrently.
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
