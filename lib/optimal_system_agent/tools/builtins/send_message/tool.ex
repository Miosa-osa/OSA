defmodule OptimalSystemAgent.Tools.Builtins.SendMessage.Tool do
  @moduledoc """
  Structured-layout tool implementation for `send_message`.

  Sends a message to another running agent by name or session ID.
  All logic lives in the sibling modules:

    * `SendMessage.Constants`  — exported atoms for cross-tool reference
    * `SendMessage.Prompt`     — dynamic prompt builder
    * `SendMessage.Handler`    — validate / check_permissions / execute / drain_pending_messages
    * `SendMessage.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.SendMessage.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["message", "msg"]

  @impl true
  def search_hint, do: "send a message to another running agent"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["to", "message"],
      "properties" => %{
        "to" => %{
          "type" => "string",
          "description" => "Target agent name or session ID"
        },
        "message" => %{
          "type" => "string",
          "description" => "Message content to send to the target agent"
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # send_message is only useful in multi-agent sessions; defer by default.
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # PubSub broadcast is process-safe; multiple agents can send concurrently.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Sends are not reversible (you can't un-send), but they produce no
  # persistent side-effects beyond the target agent's context injection.
  # Not flagged destructive so the agent loop doesn't require extra confirmation.
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
  def to_classifier_input(%{"to" => to, "message" => msg}), do: %{to: to, message: msg}
  def to_classifier_input(_), do: ""
end
