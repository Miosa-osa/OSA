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
            "Clear, specific description of the subtask to delegate. " <>
              "Include all context the subagent needs — file paths, requirements, constraints. " <>
              "The subagent has NO access to your conversation history."
        },
        "role" => %{
          "type" => "string",
          "description" =>
            "Agent role name (e.g., 'architect', 'backend', 'frontend', 'tester'). " <>
              "Must match a loaded agent definition. Omit for a generic subagent."
        },
        "subagent_type" => %{
          "type" => "string",
          "description" =>
            "Claude Code-compatible alias for role. Use the loaded agent name, " <>
              "for example 'explorer' or 'planner'."
        },
        "tier" => %{
          "type" => "string",
          "enum" => Constants.tiers(),
          "description" =>
            "Model tier — elite (strongest, slowest), specialist (balanced), " <>
              "utility (fastest, cheapest). Defaults to the role's configured tier, or 'specialist'. " <>
              "Note: utility is silently promoted to specialist — small models cannot reliably call tools."
        },
        "mode" => %{
          "type" => "string",
          "enum" => ["explore", "diagnose", "implement", "review", "test", "ship"],
          "description" =>
            "Development workflow preset. Controls default tier, permission posture, " <>
              "background behavior, and verification expectations unless explicitly overridden."
        },
        "background" => %{
          "type" => "boolean",
          "description" =>
            "Run in background — returns immediately, notifies on completion. " <>
              "Use for long-running research or analysis that doesn't block your current work."
        },
        "permissionMode" => %{
          "type" => "string",
          "enum" => ["default", "acceptEdits", "bypassPermissions", "plan", "read_only"],
          "description" =>
            "Claude Code-compatible permission mode override for the subagent. " <>
              "default uses OSA subagent guardrails; plan/read_only prevents write tools."
        },
        "maxTurns" => %{
          "type" => "integer",
          "description" => "Claude Code-compatible alias for the subagent max iteration/turn cap."
        },
        "model" => %{
          "type" => "string",
          "description" => "Optional explicit model override for this subagent."
        },
        "provider" => %{
          "type" => "string",
          "description" => "Optional provider override for this subagent."
        },
        "cwd" => %{
          "type" => "string",
          "description" =>
            "Optional working directory for the subagent. Worktree isolation takes precedence."
        },
        "fork" => %{
          "type" => "boolean",
          "description" =>
            "Fork subagent with full parent conversation context. " <>
              "The child inherits your conversation history for context-aware delegation."
        },
        "isolation" => %{
          "type" => "string",
          "enum" => ["worktree"],
          "description" =>
            "Run in an isolated git worktree — the agent gets its own copy " <>
              "of the repo. Dirty worktrees are preserved for review unless merge_worktree " <>
              "or discard_worktree is explicitly set."
        },
        "merge_worktree" => %{
          "type" => "boolean",
          "description" =>
            "When using worktree isolation, explicitly merge the agent worktree back on success."
        },
        "discard_worktree" => %{
          "type" => "boolean",
          "description" =>
            "When using worktree isolation, discard dirty worktree changes instead of preserving them."
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
