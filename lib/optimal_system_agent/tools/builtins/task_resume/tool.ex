defmodule OptimalSystemAgent.Tools.Builtins.TaskResume.Tool do
  @moduledoc """
  Structured-layout entry point for `task_resume`.

  The mirror of `TaskStop.Tool`. Declarations only; all logic lives in the
  sibling modules:

    * `TaskResume.Constants`  — exported atoms for cross-tool reference
    * `TaskResume.Prompt`     — dynamic prompt with `safe_ref` cross-tool links
    * `TaskResume.Handler`    — validate / check_permissions / execute
    * `TaskResume.UI`         — render callbacks for the Rust TUI

  ## Design decisions

  * `should_defer?` → false — task_resume must always be available so the model
    can continue a stopped teammate on any turn (mirrors task_stop).
  * `always_load?` → true — same reason; the tool is always-on.
  * `concurrency_safe?` → false — RunStore lookup + run_background dispatch are
    not atomic; concurrent resume calls for the same agent_id can race.
  * `read_only?` → false — resuming spawns a new agent run.
  * `destructive?` → false — the prior run/transcript is preserved.
  * `safety/0` → `:write_safe` — mirrors task_stop.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TaskResume.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: []

  @impl true
  def search_hint, do: "resume a stopped or backgrounded agent task by session ID"

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
          "description" => "Session ID of the agent to resume"
        },
        "message" => %{
          "type" => "string",
          "description" =>
            "Optional follow-up instruction. It restarts with its full prior " <>
              "transcript; omit to continue the original task."
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
  # `false`, and the reason is a defect this contradiction was hiding.
  #
  # `should_defer?` above already says this tool is not worth its schema on
  # every request. `always_load?` said the opposite, and the two are read by
  # DIFFERENT consumers that never compared notes:
  #
  #   * `Tools.PromptAssembler.partition/2` honours `always_load?`, so the full
  #     prose AND a re-encoded JSON schema went into the system prompt.
  #   * `Tools.Registry.list_active/0` — which is the sole source of the native
  #     `tools` array (`Registry.filter_applicable_tools/1` -> `Agent.Loop`
  #     `state.tools` -> `ReactLoop`'s `tools:` option) — consults only
  #     `should_defer?`, so the tool was dropped from it.
  #
  # The result was the worst of both: paid for on every request, and under a
  # native-tool provider (`Anthropic.native_tool_schemas?/0` is true) not
  # callable at all, because a name absent from the tools array is a name the
  # API cannot emit. Nothing re-adds it later either — `tool_search` returns a
  # formatted STRING and touches no state, so the "discoverable mid-turn"
  # promise in `should_defer?`'s comment is not kept for native providers.
  #
  # Setting this to `false` makes the tool consistently deferred: out of the
  # prompt prose, listed by name in the deferred `<system-reminder>` block, and
  # exactly as callable as it was before — which under a native provider is the
  # honest answer, and under a text-parsing provider still works via
  # `tool_search`, since the executor resolves names against the FULL registry
  # (`Registry.execute_unguarded/2`) rather than the advertised array.
  #
  # Measured cost of the contradiction across the five tools that had it:
  # 3,561 bytes / ~890 estimated tokens of static prefix on every request of
  # every session, buying zero callable capability.
  #
  # The reachability hole itself is NOT fixed here — see the note in
  # `Tools.Registry.list_active/0`.
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # RunStore lookup + dispatch are not atomic; concurrent calls can race.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Resuming preserves the prior run/transcript — no data is permanently lost.
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
