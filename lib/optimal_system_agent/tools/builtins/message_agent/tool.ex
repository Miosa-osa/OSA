defmodule OptimalSystemAgent.Tools.Builtins.MessageAgent.Tool do
  @moduledoc """
  Structured-layout tool: send and receive messages between team agents.

  Per-tool directory layout — declarations only; all logic lives in siblings:

    * `MessageAgent.Constants`  — exported atoms; referenced by `TeamTasks.Prompt`
    * `MessageAgent.Prompt`     — dynamic prompt referencing `team_tasks`
    * `MessageAgent.Handler`    — validate / check_permissions / execute
    * `MessageAgent.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.MessageAgent.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["msg_agent", "send_to_agent"]

  @impl true
  def search_hint, do: "send or receive messages between agents in a team"

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
            "send: message one agent, read: check your inbox, broadcast: message all teammates"
        },
        "team_id" => %{
          "type" => "string",
          "description" => "Team identifier."
        },
        "to" => %{
          "type" => "string",
          "description" => "Recipient agent session ID (for send action)."
        },
        "message" => %{
          "type" => "string",
          "description" => "Message content to send."
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Agents need messaging during active team sessions.
  def should_defer?, do: false

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # PubSub publish and ETS inbox writes are concurrent-safe (independent keys).
  def concurrency_safe?(_input, _ctx), do: true

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
  def to_classifier_input(%{"action" => "send", "to" => to}), do: %{action: "send", to: to}
  def to_classifier_input(%{"action" => a}), do: %{action: a}
  def to_classifier_input(_), do: ""
end
