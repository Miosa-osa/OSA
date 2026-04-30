defmodule OptimalSystemAgent.Tools.Builtins.WebFetch.Tool do
  @moduledoc """
  Structured-layout tool implementation for `web_fetch`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `WebFetch.Constants`  — exported atoms for cross-tool reference
    * `WebFetch.Prompt`     — dynamic prompt builder
    * `WebFetch.Handler`    — validate / check_permissions / execute
    * `WebFetch.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.WebFetch.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["fetch", "fetch_url"]

  @impl true
  def search_hint, do: "fetch web page content from a URL"

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
        "url" => %{
          "type" => "string",
          "description" =>
            "The URL to fetch (must be https:// except for localhost). " <>
              "HTTP URLs will be rejected unless the host is localhost/127.x/::1."
        },
        "max_length" => %{
          "type" => "integer",
          "description" =>
            "Maximum characters to return (default #{Constants.default_max_length()}). " <>
              "Content is truncated with a notice if it exceeds this limit."
        }
      },
      "required" => ["url"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Web tools are common enough to always include — no need to defer.
  def should_defer?, do: false

  @impl true
  # Always load so the model knows it can fetch URLs without requesting
  # the tool first.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Independent HTTP calls never collide with each other.
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  # Fetching a URL never mutates local state.
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  # Talks to external HTTP servers.
  def open_world?(_input, _ctx), do: true

  @impl true
  # Web pages can be large; 50K gives room for API docs, READMEs, etc.
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
  def to_classifier_input(%{"url" => url}), do: %{url: url}
  def to_classifier_input(_), do: ""
end
