defmodule OptimalSystemAgent.Tools.Builtins.Sleep.Tool do
  @moduledoc """
  Cooperative wait tool. Pairs with the cron tool for proactive
  scheduling — when the agent has nothing to do but expects something
  to change, it sleeps cooperatively rather than busy-waiting.


  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Sleep.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["wait", "pause"]

  @impl true
  def search_hint, do: "wait for a specified duration"

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "seconds" => %{
          "type" => "integer",
          "description" =>
            "How long to sleep, in seconds (min #{Constants.min_seconds()}, max #{Constants.max_seconds()})"
        },
        "reason" => %{
          "type" => "string",
          "description" => "Optional rationale shown to the user (e.g. 'waiting for build')"
        }
      },
      "required" => ["seconds"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true

  @impl true
  def max_result_size_chars, do: 1_000

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :read_only

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
  def to_classifier_input(%{"seconds" => s}), do: %{seconds: s}
  def to_classifier_input(_), do: ""
end
