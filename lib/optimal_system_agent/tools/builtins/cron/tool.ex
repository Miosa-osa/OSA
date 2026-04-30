defmodule OptimalSystemAgent.Tools.Builtins.Cron.Tool do
  @moduledoc """
  Structured-layout implementation of the `cron` tool.

  Per-tool directory layout — declarations only. All logic lives in the
  sibling modules:

    * `Cron.Constants`  — exported atoms for cross-tool reference
    * `Cron.Prompt`     — dynamic prompt covering all 4 actions
    * `Cron.Handler`    — validate / check_permissions / execute
    * `Cron.UI`         — render callbacks for the Rust TUI cron panel

  The tool is **deferred** (`should_defer? true`): it stays out of the
  always-loaded prompt section and is discoverable via ToolSearch. This
  matches the flat tool's `deferred? -> true` and the Claude Code reference
  `shouldDefer: true` on all three ScheduleCronTool variants.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Cron.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["schedule", "schedule_task"]

  @impl true
  def search_hint, do: "schedule recurring or one-time tasks"

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
          "enum" => Constants.action_strings(),
          "description" => "Action to perform: create, list, delete, or trigger"
        },
        "task" => %{
          "type" => "string",
          "description" => "Natural-language task description (required for create)"
        },
        "schedule" => %{
          "type" => "string",
          "description" =>
            "Cron expression (\"0 */6 * * *\") or preset (\"hourly\", \"daily\", \"weekly\"). Required for create."
        },
        "job_id" => %{
          "type" => "string",
          "description" => "Job ID returned by create (required for delete and trigger)"
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────

  @impl true
  # Cron is not a hot-path tool; the model discovers it via ToolSearch.
  # Matches the flat layout's `deferred? -> true` and Claude Code's
  # `shouldDefer: true` on CronCreateTool/CronListTool/CronDeleteTool.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────

  @impl true
  # The Scheduler GenServer serializes all state mutations; concurrent
  # calls are safe from the caller's POV but the tool itself is not
  # idempotent, so we declare false to avoid parallel double-scheduling.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(input, _ctx), do: input["action"] == "list"

  @impl true
  def destructive?(input, _ctx), do: input["action"] == "delete"

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
  def to_classifier_input(%{"action" => action, "task" => task}),
    do: %{action: action, task: task}

  def to_classifier_input(%{"action" => action, "job_id" => id}),
    do: %{action: action, job_id: id}

  def to_classifier_input(%{"action" => action}),
    do: %{action: action}

  def to_classifier_input(_), do: ""
end
