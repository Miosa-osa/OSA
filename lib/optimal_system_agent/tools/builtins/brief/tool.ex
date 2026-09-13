defmodule OptimalSystemAgent.Tools.Builtins.Brief.Tool do
  @moduledoc """
  Summarise recent agent activity into a 1-paragraph brief.

  Reads from the same memory store as `memory_recall` and condenses
  task completions, tool calls, decisions, and errors within the
  requested time window into a scannable summary.

  Defers by default — the model invokes it on demand via tool_search.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Brief.{Constants, Handler, Prompt, UI}

  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["summarize", "summary", "catch_up"]

  @impl true
  def search_hint, do: "generate a brief summary of recent agent activity"

  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "window_hours" => %{
          "type" => "integer",
          "description" =>
            "How far back to look (hours). One of: #{Enum.join(Constants.valid_windows(), ", ")}. " <>
              "Defaults to #{Constants.default_window_hours()}.",
          "enum" => Constants.valid_windows()
        },
        "topic" => %{
          "type" => "string",
          "description" =>
            "Optional keyword filter. Narrows the brief to entries that match " <>
              "this topic (same keyword index as memory_recall)."
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
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: 3_000

  # ── Safety ────────────────────────────────────────────────────────────
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
  def to_classifier_input(%{"window_hours" => h} = input) do
    %{window_hours: h, topic: Map.get(input, "topic")}
  end

  def to_classifier_input(input) when is_map(input) do
    %{window_hours: Constants.default_window_hours(), topic: Map.get(input, "topic")}
  end

  def to_classifier_input(_), do: ""
end
