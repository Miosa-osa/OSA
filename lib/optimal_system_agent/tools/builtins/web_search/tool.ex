defmodule OptimalSystemAgent.Tools.Builtins.WebSearch.Tool do
  @moduledoc """
  Structured-layout tool implementation for `web_search`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `WebSearch.Constants`  — exported atoms for cross-tool reference
    * `WebSearch.Prompt`     — dynamic prompt builder (includes current date)
    * `WebSearch.Handler`    — validate / check_permissions / execute
    * `WebSearch.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.WebSearch.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["search", "search_web"]

  @impl true
  def search_hint, do: "search the web for information using DuckDuckGo"

  # ── Schema & description ──────────────────────────────────────────────
  @impl true
  def description, do: Prompt.render([])

  @impl true
  def prompt(opts), do: Prompt.render(opts)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query. Include the current year for time-sensitive topics."
        },
        "limit" => %{
          "type" => "integer",
          "description" =>
            "Maximum number of results to return (default #{Constants.default_limit()}). " <>
              "Capped at 10 by the underlying search engine."
        }
      },
      "required" => ["query"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Web tools are common enough to always include — no need to defer.
  def should_defer?, do: false

  @impl true
  # Always load so the model knows it can search without requesting
  # the tool first.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Independent HTTP calls to DuckDuckGo never collide with each other.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  # Searching the web never mutates local state.
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  # Talks to DuckDuckGo's external servers.
  def open_world?(_input, _ctx), do: true

  @impl true
  # Search result pages can be large; 50K gives room for many results.
  def max_result_size_chars, do: 50_000

  # ── Flat-layout compatibility ─────────────────────────────────────────
  @impl true
  def safety, do: :read_only

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
  def to_classifier_input(%{"query" => q}), do: %{query: q}
  def to_classifier_input(_), do: ""
end
