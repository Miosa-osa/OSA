defmodule OptimalSystemAgent.Tools.Builtins.TaskWrite.Tool do
  @moduledoc """
  Structured-layout entry point for `task_write`.

  Per-tool directory layout — declarations only; all logic lives in the
  sibling modules:

    * `TaskWrite.Constants`  — exported atoms for cross-tool reference
    * `TaskWrite.Prompt`     — dynamic prompt mirroring TodoWriteTool semantics
    * `TaskWrite.Handler`    — validate / check_permissions / execute
    * `TaskWrite.UI`         — render callbacks for the Rust TUI

  ## Design decisions

  * `should_defer?` → false — task_write is always-on (the TodoWrite
    is never deferred; it must be in every prompt so the model tracks its plan).
  * `always_load?` → true — same reason: the model needs it available unconditionally.
  * `concurrency_safe?` → false — mutates shared GenServer state.
  * `read_only?` → false — `list`/`next` are reads but we err on the side of
    caution to prevent race conditions with concurrent write actions.
  * `destructive?` → false — all state changes are reversible (clear can be
    undone by re-adding tasks; no data is permanently lost).
  * `safety/0` → `:write_safe` — matches the original flat-layout value.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TaskWrite.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: []

  @impl true
  def search_hint, do: "create and manage structured task lists for multi-step work plans"

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
        "action" => %{
          "type" => "string",
          "enum" => Constants.actions(),
          "description" => "Operation to perform"
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Session ID (auto-detected if omitted)"
        },
        "task_id" => %{
          "type" => "string",
          "description" =>
            "Task ID (for start/complete/fail/update/add_dependency/remove_dependency)"
        },
        "title" => %{
          "type" => "string",
          "description" => "Task title (for add)"
        },
        "titles" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Multiple task titles (for add_multiple)"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Failure reason (for fail)"
        },
        "description" => %{
          "type" => "string",
          "description" => "Detailed task description"
        },
        "blocked_by" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Task IDs that block this task"
        },
        "owner" => %{
          "type" => "string",
          "description" => "Agent/role that owns this task"
        },
        "metadata" => %{
          "type" => "object",
          "description" => "Arbitrary metadata key-value pairs"
        },
        "blocker_id" => %{
          "type" => "string",
          "description" => "Blocking task ID (for add_dependency/remove_dependency)"
        }
      },
      "required" => ["action"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # task_write is always-on — the model must have it available every turn so
  # it can update its plan without waiting for a deferred load. This mirrors
  # the TodoWrite behaviour in the upstream contract: it is never deferred.
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Mutates the shared Tasks GenServer — concurrent calls can interleave
  # and produce unexpected ordering.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  # Even list/next are read-like, we return false so the loop serialises
  # all task_write calls through the single GenServer mailbox safely.
  def read_only?(_input, _ctx), do: false

  @impl true
  # clear wipes the board but the model can re-add tasks; nothing is
  # permanently deleted from storage.
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
  def to_classifier_input(%{"action" => a, "title" => t}), do: %{action: a, title: t}
  def to_classifier_input(%{"action" => a}), do: %{action: a}
  def to_classifier_input(_), do: ""
end
