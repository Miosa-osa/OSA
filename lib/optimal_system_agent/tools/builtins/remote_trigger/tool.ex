defmodule OptimalSystemAgent.Tools.Builtins.RemoteTrigger.Tool do
  @moduledoc  """
  External-trigger management tool.

  Pairs with `cron` (recurring schedules) and `monitor` (active polls) as
  the third proactive scheduling primitive — a passive listener that
  external systems can fire to wake a scheduled job.

  Mirrors upstream from the the upstream contract,
  on top of OSA's existing `Agent.Scheduler` trigger infrastructure.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.RemoteTrigger.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["trigger"]

  @impl true
  def search_hint, do: "register and fire external triggers and webhooks"

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
          "description" => "Operation: create, list, remove, fire"
        },
        "trigger_id" => %{
          "type" => "string",
          "description" => "Trigger ID (required for fire/remove)"
        },
        "type" => %{
          "type" => "string",
          "description" =>
            "Trigger type (required for create) — e.g. 'webhook', 'signal', 'manual'"
        },
        "job_id" => %{
          "type" => "string",
          "description" => "Linked scheduled job ID (for create)"
        },
        "payload_schema" => %{
          "type" => "object",
          "description" => "Optional JSON schema describing the expected fire payload"
        },
        "payload" => %{
          "type" => "object",
          "description" => "Payload map sent to the linked job (for fire)"
        }
      },
      "required" => ["action"]
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
  def read_only?(%{"action" => "list"}, _ctx), do: true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(%{"action" => "remove"}, _ctx), do: true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: 10_000

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
  def to_classifier_input(%{"action" => a, "trigger_id" => id}),
    do: %{action: a, trigger_id: id}

  def to_classifier_input(%{"action" => a}), do: %{action: a}
  def to_classifier_input(_), do: ""
end
