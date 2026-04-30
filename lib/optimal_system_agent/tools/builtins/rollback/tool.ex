defmodule OptimalSystemAgent.Tools.Builtins.Rollback.Tool do
  @moduledoc """
  Structured-layout rollback tool implementation.

  Provides list / diff / restore actions over the FSCheckpoint shadow git
  repo. The tool is deferred (not always loaded into the system prompt) and
  only available when fs_checkpoints_enabled is true.

  Per-tool directory layout:
    * `Rollback.Constants`  — exported tool name atom
    * `Rollback.Prompt`     — dynamic prompt builder
    * `Rollback.Handler`    — validate / check_permissions / execute
    * `Rollback.Tool`       — this file — wires the Behaviour contract
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Rollback.{Constants, Handler, Prompt}

  # ── Identity ──────────────────────────────────────────────────────────

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["checkpoint_rollback", "fs_rollback"]

  @impl true
  def search_hint, do: "restore files from a pre-operation filesystem checkpoint"

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
          "enum" => ["list", "diff", "restore"],
          "description" =>
            "Action to perform: list checkpoints, diff a checkpoint, or restore files from a checkpoint"
        },
        "checkpoint_id" => %{
          "type" => "string",
          "description" =>
            "Checkpoint ID (short hash from list output). Required for diff and restore actions."
        },
        "limit" => %{
          "type" => "integer",
          "description" =>
            "Number of checkpoints to list (default 20). Only used with list action."
        }
      },
      "required" => ["action"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────

  @impl true
  # Defer rollback from the default system prompt — it is loaded on demand
  # when the agent needs to recover from a bad edit.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  @impl true
  def available?, do: OptimalSystemAgent.FSCheckpoint.Config.enabled?()

  # ── Execution semantics (per-input) ───────────────────────────────────

  @impl true
  # restore mutates the filesystem but list/diff are safe; fail conservative.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # restore is intentional recovery, not net-new destruction.
  def destructive?(_input, _ctx), do: false

  @impl true
  def safety, do: :safe

  # ── Two-stage permissioning ───────────────────────────────────────────

  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  # ── Execution ─────────────────────────────────────────────────────────

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)
end
