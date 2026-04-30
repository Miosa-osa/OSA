defmodule OptimalSystemAgent.Tools.Builtins.Monitor.Tool do
  @moduledoc  """
  Cooperative watch tool — blocks until a target changes.

  Pairs with `cron` (scheduled triggers) and `sleep` (unconditional wait)
  to give the agent proactive scheduling primitives. Mirrors
  upstream from the the upstream contract, simplified to
  the 4 watch kinds OSA cares about.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Monitor.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["watch"]

  @impl true
  def search_hint, do: "watch a file, process, URL, or command for changes"

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{
          "type" => "string",
          "enum" => Constants.kinds(),
          "description" =>
            "What to watch: file mtime, process exit, URL status, or command output"
        },
        "target" => %{
          "type" => "string",
          "description" => "The thing to watch — file path, pid string, URL, or shell command"
        },
        "duration_seconds" => %{
          "type" => "integer",
          "description" =>
            "Maximum wait in seconds (1..#{Constants.max_duration_seconds()}). Defaults to 60."
        },
        "poll_interval_ms" => %{
          "type" => "integer",
          "description" =>
            "How often to re-sample, in milliseconds. Defaults to #{Constants.default_poll_interval_ms()}."
        }
      },
      "required" => ["kind", "target"]
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
  def open_world?(%{"kind" => kind}, _ctx) when kind in ["url", "command"], do: true
  def open_world?(_input, _ctx), do: false

  @impl true
  def interrupt_behavior, do: :cancel

  @impl true
  def max_result_size_chars, do: 5_000

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
  def to_classifier_input(%{"kind" => k, "target" => t}), do: %{kind: k, target: t}
  def to_classifier_input(_), do: ""
end
