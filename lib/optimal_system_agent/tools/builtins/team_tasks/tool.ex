defmodule OptimalSystemAgent.Tools.Builtins.TeamTasks.Tool do
  @moduledoc """
  Structured-layout tool: view and manage the shared team task list.

  Per-tool directory layout — declarations only; all logic lives in siblings:

    * `TeamTasks.Constants`  — exported atoms for cross-tool reference
    * `TeamTasks.Prompt`     — dynamic prompt referencing `message_agent`
    * `TeamTasks.Handler`    — validate / check_permissions / execute
    * `TeamTasks.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.TeamTasks.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["tasks", "team_task_list"]

  @impl true
  def search_hint, do: "view and manage the shared team task list"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => Constants.valid_actions(),
          "description" =>
            "Action: list (view all tasks), claim (take a pending task), " <>
              "complete (mark done), scratchpad_write (save notes), scratchpad_read (read team notes)"
        },
        "team_id" => %{
          "type" => "string",
          "description" => "Team identifier. Required for all actions."
        },
        "task_id" => %{
          "type" => "string",
          "description" => "Task ID for claim/complete actions."
        },
        "result" => %{
          "type" => "string",
          "description" => "Result text when completing a task."
        },
        "content" => %{
          "type" => "string",
          "description" => "Content for scratchpad_write."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Agents need this during active team sessions — don't defer.
  def should_defer?, do: false

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # claim/complete/scratchpad_write mutate shared ETS state — not concurrent-safe.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
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
  def to_classifier_input(%{"action" => a, "task_id" => t}), do: %{action: a, task_id: t}
  def to_classifier_input(%{"action" => a}), do: %{action: a}
  def to_classifier_input(_), do: ""
end
