defmodule OptimalSystemAgent.Tools.Builtins.Delegate.Tool do
  @moduledoc """
  Structured-layout tool implementation for `delegate`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `Delegate.Constants`  — exported atoms for cross-tool reference
    * `Delegate.Prompt`     — dynamic prompt builder
    * `Delegate.Handler`    — validate / check_permissions / execute
    * `Delegate.UI`         — render callbacks for the Rust TUI

  ## Loading semantics
    * `always_load?` → true  — the model uses delegate frequently;
      keeping it in every prompt avoids a tool-search round-trip.
    * `should_defer?` → false — must be available from turn 1.

  ## Execution semantics
    * `concurrency_safe?` → true  — each delegation is an independent
      subprocess with its own context and BEAM process tree.
    * `read_only?`        → false — subagents can write files, run shells, etc.
    * `destructive?`      → false — destructive accountability sits with the
      subagent's own tools, not the delegate call itself.
    * `safety/0`          → :subagent — custom tier used by permission rules
      and the tool filter to apply subagent-specific guardrails.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Delegate.{Constants, Handler, Prompt, UI}

  # ── Identity ───────────────────────────────────────────────────────────

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["agent", "subagent", "spawn_agent"]

  @impl true
  def search_hint, do: "delegate subtask to a specialized subagent"

  # ── Schema & description ───────────────────────────────────────────────

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["task"],
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" =>
            "The subtask, fully self-contained. The subagent has NOT seen this " <>
              "conversation — brief it like a colleague who just walked in: the " <>
              "objective and why, every relevant path, the constraints and forbidden " <>
              "actions, the verification you require, and the expected output shape " <>
              "and stop condition. Terse command-style prompts produce shallow work."
        },
        "tasks" => %{
          "type" => "array",
          "description" =>
            "Fan-out: subtasks run in PARALLEL as one wave, then synthesized. " <>
              "'task' becomes the umbrella description. Omit for a single delegation. " <>
              "For parallel work prefer ONE call with tasks:[...] over sequential calls.",
          "items" => %{
            "type" => "object",
            "required" => ["prompt"],
            "properties" => %{
              "prompt" => %{
                "type" => "string",
                "description" => "Self-contained task for this worker."
              },
              "subagent_type" => %{
                "type" => "string",
                "description" => "Optional role for this worker."
              }
            }
          }
        },
        "name" => %{
          "type" => "string",
          "description" =>
            "Stable teammate handle shown as @name, e.g. 'smoke-e2e'. Omit to auto-number."
        },
        "role" => %{
          "type" => "string",
          "description" =>
            "Agent role; must match a loaded definition. Omit for a generic subagent."
        },
        "subagent_type" => %{
          "type" => "string",
          "description" => "Alias for role."
        },
        "tier" => %{
          "type" => "string",
          "enum" => Constants.tiers(),
          "description" =>
            "elite (strongest) / specialist (balanced) / utility (fastest, silently " <>
              "promoted to specialist). Defaults to the role's tier."
        },
        "background" => %{
          "type" => "boolean",
          "description" => "Default true. False BLOCKS you and the user until the agent returns."
        },
        "permissionMode" => %{
          "type" => "string",
          "enum" => ["default", "acceptEdits", "bypassPermissions", "plan", "read_only"],
          "description" => "Subagent permission override. plan/read_only forbid write tools."
        },
        "maxTurns" => %{
          "type" => "integer",
          "description" => "Subagent turn cap."
        },
        "max_budget_usd" => %{
          "type" => "number",
          "description" =>
            "Per-subagent USD spend ceiling. The subagent stops itself once it " <>
              "crosses this cap. Omit for no cap. Use on wide fan-outs to bound total spend."
        },
        "priority" => %{
          "type" => "string",
          "enum" => ["immediate", "standard", "loose"],
          "description" =>
            "Speed/cost tier. 'loose' (non-urgent, long-horizon work) routes to a " <>
              "cheaper model and prefers free/local providers to cut cost; 'immediate' " <>
              "picks the best model; 'standard' (default) is balanced."
        },
        "model" => %{
          "type" => "string",
          "description" => "Model override for this subagent."
        },
        "provider" => %{
          "type" => "string",
          "description" => "Provider override for this subagent."
        },
        "cwd" => %{
          "type" => "string",
          "description" => "Working directory. Worktree isolation takes precedence."
        },
        "fork" => %{
          "type" => "boolean",
          "description" => "Give the subagent your full conversation history."
        },
        "resume_from_agent_id" => %{
          "type" => "string",
          "description" =>
            "Seed from a PEER agent's context instead of your own — sibling handoff. " <>
              "Takes precedence over 'fork'; starts fresh if that peer is still running."
        },
        "isolation" => %{
          "type" => "string",
          "enum" => ["worktree"],
          "description" =>
            "Run in an isolated git worktree. Dirty worktrees are preserved unless " <>
              "merge_worktree or discard_worktree is set."
        },
        "merge_worktree" => %{
          "type" => "boolean",
          "description" => "Merge the agent's worktree back on success."
        },
        "discard_worktree" => %{
          "type" => "boolean",
          "description" => "Discard dirty worktree changes instead of preserving them."
        },
        "reconcile" => %{
          "type" => "boolean",
          "description" =>
            "Fan-out only: run a coordinator that reconciles all reports into one " <>
              "deliverable. Default false (plain concatenation)."
        },
        "coordinator_role" => %{
          "type" => "string",
          "description" => "Role for the reconcile coordinator. Only used when reconcile is true."
        }
      }
    }
  end

  # ── Loading semantics ──────────────────────────────────────────────────

  @impl true
  # Delegate must be available from turn 1 — models use it without tool-search.
  def should_defer?, do: false

  @impl true
  # Keep delegate in every prompt; tool-search round-trips add latency to
  # the critical orchestration path.
  def always_load?, do: true

  # ── Execution semantics ────────────────────────────────────────────────

  @impl true
  # Each delegation spawns an independent subprocess — no shared state.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  # Subagents can write files, run shells, execute code. Not read-only.
  def read_only?(_input, _ctx), do: false

  @impl true
  # Destructive accountability sits with the subagent's own tools and their
  # permission tiers, not the delegate call itself.
  def destructive?(_input, _ctx), do: false

  @impl true
  # Subagents can contact external services, fetch URLs, run arbitrary code.
  def open_world?(_input, _ctx), do: true

  @impl true
  # Subagents can run for minutes. Don't auto-persist — result is a short
  # synthesis string, not a large blob.
  def max_result_size_chars, do: 10_000

  # ── Flat-layout compatibility ──────────────────────────────────────────

  @impl true
  # Custom safety tier; permission rules and tool_filter use :subagent to
  # apply subagent-specific guardrails (max nesting depth, budget caps, etc.)
  def safety, do: :subagent

  # ── Two-stage permissioning ────────────────────────────────────────────

  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ──────────────────────────────────────────────────────────

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  # ── Rendering ──────────────────────────────────────────────────────────

  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  # ── Classifier input ───────────────────────────────────────────────────

  @impl true
  def to_classifier_input(%{"task" => task}), do: %{task: task}
  def to_classifier_input(_), do: ""
end
