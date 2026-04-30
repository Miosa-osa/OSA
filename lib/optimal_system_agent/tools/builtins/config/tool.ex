defmodule OptimalSystemAgent.Tools.Builtins.Config.Tool do
  @moduledoc """
  Structured-layout tool implementation for `config`.

  Reads or writes OSA configuration settings through the Settings cascade
  (session → local → project → user). All logic lives in the sibling modules:

    * `Config.Constants`  — exported atoms for cross-tool reference
    * `Config.Prompt`     — dynamic prompt builder
    * `Config.Handler`    — validate / check_permissions / execute
    * `Config.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Config.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["settings", "cfg"]

  @impl true
  def search_hint, do: "read or write OSA configuration settings"

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
          "enum" => ["get", "set", "list"],
          "description" => "Action to perform"
        },
        "key" => %{
          "type" => "string",
          "description" => "Setting key (required for get/set)"
        },
        "value" => %{
          "type" => "string",
          "description" => "Setting value (required for set)"
        },
        "layer" => %{
          "type" => "string",
          "enum" => ["user", "project", "session"],
          "description" => "Which settings layer to write to (default: session)"
        }
      }
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # config is rarely needed; defer until the model requests it.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  # get/list are concurrent-safe; set serialises through the Settings GenServer.
  def concurrency_safe?(%{"action" => action}, _ctx)
      when action in ["get", "list"],
      do: true

  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  # read_only only for get/list
  def read_only?(%{"action" => action}, _ctx)
      when action in ["get", "list"],
      do: true

  def read_only?(_input, _ctx), do: false

  @impl true
  # set writes are not destructive — settings can be reverted
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  # ── Flat-layout compatibility ─────────────────────────────────────────
  # Config is mixed read/write; report :write_safe so the adapter does not
  # flag it as destructive, but also does not assume read_only.
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
  def to_classifier_input(%{"action" => action} = input),
    do: %{action: action, key: input["key"]}

  def to_classifier_input(_), do: ""
end
