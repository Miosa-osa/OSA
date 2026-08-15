defmodule OptimalSystemAgent.Tools.Builtins.ExitWorktree.Tool do
  @moduledoc """
  Remove or finalize a git worktree created by enter_worktree.

  Call this when finished with an isolated worktree. Supports merge-back
  (commits outstanding changes then merges the branch) or discard (removes
  the worktree and optionally the branch, leaving the main tree untouched).

  Destructive: can permanently delete a worktree directory tree.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ExitWorktree.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["worktree_exit", "worktree_remove"]

  @impl true
  def search_hint, do: "remove or merge back a git worktree created by enter_worktree"

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Absolute path of the worktree to remove, as returned by enter_worktree."
        },
        "merge" => %{
          "type" => "boolean",
          "description" =>
            "When true, stage + commit outstanding changes and merge the worktree branch " <>
              "back into the current branch before removing. Defaults to false."
        },
        "keep" => %{
          "type" => "boolean",
          "description" =>
            "When true, leave the worktree directory on disk after removing git bookkeeping. " <>
              "Useful for post-mortem inspection. Defaults to false."
        },
        "force" => %{
          "type" => "boolean",
          "description" =>
            "When true, pass --force to git worktree remove so uncommitted changes are " <>
              "discarded without error. Ignored when merge: true. Defaults to false."
        }
      },
      "required" => ["path"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: true

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true

  @impl true
  def max_result_size_chars, do: 2_000

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :write_safe

  # ── Pipeline ──────────────────────────────────────────────────────────
  @impl true
  def validate_input(input, ctx), do: Handler.validate(input, ctx)

  @impl true
  def check_permissions(input, ctx), do: Handler.check_permissions(input, ctx)

  @impl true
  def execute(input, ctx), do: Handler.execute(input, ctx)

  @impl true
  def render(stage, payload, opts), do: UI.render(stage, payload, opts)

  @impl true
  def to_classifier_input(%{"path" => p}), do: %{path: p}
  def to_classifier_input(_), do: ""
end
