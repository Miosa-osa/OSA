defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Tool do
  @moduledoc """
  Structured-layout tool implementation for `file_grep`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `FileGrep.Constants`  — exported atoms for cross-tool reference
    * `FileGrep.Prompt`     — dynamic prompt builder
    * `FileGrep.Handler`    — validate / check_permissions / execute
    * `FileGrep.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.FileGrep.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["grep", "search_files"]

  @impl true
  def search_hint, do: "search file contents using regex pattern"

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
        "pattern" => %{"type" => "string", "description" => "Regex pattern to search for"},
        "path" => %{
          "type" => "string",
          "description" => "File or directory to search (default: cwd)"
        },
        "glob" => %{
          "type" => "string",
          "description" => "File filter glob, e.g. '*.ex'"
        },
        "case_insensitive" => %{
          "type" => "boolean",
          "description" => "Case-insensitive search (default false)"
        },
        "context_lines" => %{
          "type" => "integer",
          "description" => "Lines of context around each match"
        },
        "output_mode" => %{
          "type" => "string",
          "enum" => ["content", "files_with_matches", "count"],
          "description" => "Result shape (default files_with_matches)"
        },
        "max_results" => %{
          "type" => "integer",
          "description" => "Max matches per file (default 50)"
        }
      },
      "required" => ["pattern"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # Search is a hot path — the upstream agent CLI makes Grep always-load so the
  # model can call it without a tool-discovery round trip.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  # Generous but bounded — grep can return large output when searching
  # broad directories with context lines enabled.
  def max_result_size_chars, do: 100_000

  # ── Flat-layout compatibility ──────────────────────────────────────────────────
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
  def to_classifier_input(%{"pattern" => p, "path" => path}), do: %{pattern: p, path: path}
  def to_classifier_input(%{"pattern" => p}), do: %{pattern: p}
  def to_classifier_input(_), do: ""
end
