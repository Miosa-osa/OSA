defmodule OptimalSystemAgent.Tools.Builtins.Fleet.Tool do
  @moduledoc """
  Structured-layout tool: `fleet` — reach the full-power fleet.

  Unlike `delegate` (the restricted `Orchestrator.run_subagent` path), `fleet`
  spawns FULL-POWER peer OSA agents via `Agent.Fleet`. Two actions:

    * `"spawn"`    — spawn ONE full-power peer at any effort. The "fire off
      5-10 peers" path (`Agent.Fleet.spawn_fleet_node/2`).
    * `"workflow"` — run a dynamic workflow over a list of `items` through the
      bounded-concurrency (16) queue-drain (`Agent.Fleet.fan_out/3`).
      ULTRA-GATED: below the ultra effort tier this returns a clear "raise
      effort to ultra" message instead of running.

  Logic lives in `Fleet.Handler`; this module is declarations only, mirroring
  the `Delegate.Tool` / `Scratchpad.Tool` split.

  ## Loading semantics
    * `always_load?` → false — orchestration surface, discoverable via
      tool-search; not needed in every prompt.
    * `should_defer?` → false — usable from turn 1 when present.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Fleet.Handler

  # ── Identity ───────────────────────────────────────────────────────────

  @impl true
  def name, do: "fleet"

  @impl true
  def aliases, do: ["fleet_spawn", "fleet_workflow", "spawn_fleet_node", "fan_out"]

  @impl true
  def search_hint,
    do: "spawn full-power peer agents (spawn) or run an ultra-gated dynamic workflow (workflow)"

  # ── Schema & description ───────────────────────────────────────────────

  @impl true
  def description do
    """
    Reach the FULL-POWER fleet — peer OSA agents (not restricted delegate \
    workers). Two actions:

    - action "spawn": spawn ONE full-power peer OSA agent (any effort). Give a \
      `task` and optional `agent_type` (default "general-purpose") and \
      `working_dir`. Returns the node_id; the peer runs in the background and \
      reports on the fleet roster. Call repeatedly to fire off 5-10 peers.
    - action "workflow": run a DYNAMIC WORKFLOW over an array of string `items` \
      via a bounded-concurrency (16) queue-drain. ULTRA-GATED — raise effort to \
      ultra to use it. Each item becomes one full-power peer; `agent_type` and \
      an umbrella `task` (workflow description) apply to all.
    """
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["spawn", "workflow"],
          "description" =>
            "spawn = one full-power peer (any effort). " <>
              "workflow = dynamic workflow over `items` (ULTRA-GATED)."
        },
        "task" => %{
          "type" => "string",
          "description" =>
            "For action 'spawn': the task that drives the peer's first turn " <>
              "(required). For action 'workflow': the umbrella workflow " <>
              "description recorded in the shared scratchpad header."
        },
        "items" => %{
          "type" => "array",
          "description" =>
            "For action 'workflow' (required): the list of task strings, one " <>
              "full-power peer per item, drained at up to 16 concurrent.",
          "items" => %{
            "type" => "string",
            "description" => "A self-contained task for one workflow node."
          }
        },
        "agent_type" => %{
          "type" => "string",
          "description" =>
            "Agent-type identity selecting the peer's system prompt + tool " <>
              "allowlist (e.g. 'general-purpose', 'code-reviewer'). " <>
              "Defaults to 'general-purpose'."
        },
        "working_dir" => %{
          "type" => "string",
          "description" =>
            "Optional working directory for the spawned peer(s). Defaults to the " <>
              "shared workspace cwd."
        },
        "isolation" => %{
          "type" => "boolean",
          "description" =>
            "For action 'workflow' (default false): run EACH item in its OWN git " <>
              "worktree so parallel peers editing files never collide with each " <>
              "other or the main tree. Required before `finalize` can merge."
        },
        "finalize" => %{
          "type" => "boolean",
          "description" =>
            "For action 'workflow' (default false): after the wave, merge the " <>
              "isolated worktree diffs, run the `gate`, and commit (attribution-" <>
              "clean) when green. Requires `isolation: true` — otherwise skipped."
        },
        "gate" => %{
          "type" => "array",
          "description" =>
            "For action 'workflow' finalize: shell commands run in order as the " <>
              "ONE authoritative gate (e.g. 'mix compile', 'mix test'). The first " <>
              "non-zero exit fails the gate and blocks the commit.",
          "items" => %{
            "type" => "string",
            "description" => "One gate shell command."
          }
        },
        "commit_message" => %{
          "type" => "string",
          "description" =>
            "For action 'workflow' finalize: commit message used VERBATIM when the " <>
              "gate passes and there are no conflicts. Omit to merge + gate without " <>
              "committing."
        }
      }
    }
  end

  # ── Loading semantics ──────────────────────────────────────────────────

  @impl true
  # DEFERRED, overriding an earlier deliberate `false`.
  #
  # The original reasoning was that this should be usable from turn 1. That is
  # a testable claim and the measurement contradicts it: across 15 SWE-bench Pro
  # transcripts covering 863 turns and 963 tool calls, this tool was invoked
  # ZERO times while its schema was re-sent on every single request.
  #
  # Reason it is safe to defer: fleet MANAGEMENT. `delegate` remains loaded as the entry point, so the
  # capability is still reachable from turn 1; only its management surface
  # waits until there is something to manage.
  #
  # Nothing is lost — deferred tools stay registered and discoverable mid-turn
  # through `tool_search`. What changes is that the model is no longer billed
  # for a description it never reads.
  #
  # Reopen this if a workload appears where it IS called early. The measurement
  # is from coding tasks; it is not a claim about every workload.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ────────────────────────────────────────────────

  @impl true
  # Each spawn is an independent background peer — no shared caller state.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  # Peers can write files, run shells, execute code.
  def read_only?(_input, _ctx), do: false

  @impl true
  # Destructive accountability sits with each peer's own tools + permission
  # tiers, not the fleet call itself.
  def destructive?(_input, _ctx), do: false

  @impl true
  # Peers can contact external services, fetch URLs, run arbitrary code.
  def open_world?(_input, _ctx), do: true

  @impl true
  def max_result_size_chars, do: 10_000

  # ── Flat-layout compatibility ──────────────────────────────────────────

  @impl true
  # Custom subagent tier — permission rules + tool_filter apply spawning
  # guardrails (max depth, delegation policy) as they do for `delegate`.
  def safety, do: :subagent

  # ── Two-stage permissioning ────────────────────────────────────────────

  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ──────────────────────────────────────────────────────────

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Classifier input ───────────────────────────────────────────────────

  @impl true
  def to_classifier_input(%{"action" => a, "task" => t}), do: %{action: a, task: t}
  def to_classifier_input(%{"action" => a}), do: %{action: a}
  def to_classifier_input(_), do: ""
end
