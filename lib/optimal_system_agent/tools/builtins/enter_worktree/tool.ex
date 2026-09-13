defmodule OptimalSystemAgent.Tools.Builtins.EnterWorktree.Tool do
  @moduledoc """
  Isolate risky changes in a git worktree.

  Creates a new git worktree on a fresh branch so the agent can make
  experimental changes without touching the main working tree. Returns
  the absolute path of the new worktree for use as a working directory
  in subsequent tool calls.

  Pair with `exit_worktree` to merge back or discard when done.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.EnterWorktree.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["worktree_enter", "worktree_create"]

  @impl true
  def search_hint, do: "isolate changes in a git worktree on a fresh branch"

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "branch" => %{
          "type" => "string",
          "description" =>
            "Branch name to create in the worktree. " <>
              "Defaults to an auto-generated name like osa-wt-<timestamp>. " <>
              "Must not already be checked out in another worktree."
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Absolute or relative path where the worktree directory should be created. " <>
              "Defaults to ~/.osa/worktrees/<branch>. " <>
              "Must not already exist."
        }
      },
      "required" => []
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
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

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
  def to_classifier_input(%{"branch" => b}), do: %{branch: b}
  def to_classifier_input(_), do: ""
end
