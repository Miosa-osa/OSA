defmodule OptimalSystemAgent.Tools.Builtins.SubscribePr.Tool do
  @moduledoc """
  Subscribe to GitHub Pull Request events via periodic cron polling.

  Registers a named job in the `cron` scheduler (Agent.Scheduler) that
  polls the PR state on the requested interval and wakes the agent when a
  watched event fires.

  Not concurrency_safe because the Scheduler's job list is stateful and
  concurrent register/remove calls could race. Callers should serialise.

  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.SubscribePr.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["watch_pr", "pr_subscribe"]

  @impl true
  def search_hint, do: "subscribe to GitHub PR events via cron polling"

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pr_url" => %{
          "type" => "string",
          "description" => "Full GitHub PR URL: https://github.com/owner/repo/pull/N"
        },
        "events" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => Constants.valid_events()},
          "description" =>
            "Events to watch. One or more of: #{Enum.join(Constants.valid_events(), ", ")}. " <>
              "Default: #{Enum.join(Constants.default_events(), ", ")}"
        },
        "poll_interval_minutes" => %{
          "type" => "integer",
          "enum" => Constants.valid_poll_intervals(),
          "description" =>
            "How often to poll (minutes). One of: #{Enum.join(Enum.map(Constants.valid_poll_intervals(), &to_string/1), ", ")}. " <>
              "Default: #{Constants.default_poll_interval_minutes()}"
        }
      },
      "required" => ["pr_url"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics ───────────────────────────────────────────────
  # Not concurrency_safe — Scheduler state mutation must be serialised
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: true

  @impl true

  @impl true
  def max_result_size_chars, do: 2_000

  # ── Safety ────────────────────────────────────────────────────────────
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
  def to_classifier_input(%{"pr_url" => url} = input) do
    %{
      pr_url: url,
      events: Map.get(input, "events", Constants.default_events()),
      poll_interval_minutes:
        Map.get(input, "poll_interval_minutes", Constants.default_poll_interval_minutes())
    }
  end

  def to_classifier_input(_), do: ""
end
