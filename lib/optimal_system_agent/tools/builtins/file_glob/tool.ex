defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Tool do
  @moduledoc """
  Structured-layout tool implementation for `file_glob`.

  Per-tool directory layout — declarations only; logic lives in sibling modules:

    * `FileGlob.Constants`  — exported atoms for cross-tool reference
    * `FileGlob.Prompt`     — dynamic prompt builder
    * `FileGlob.Handler`    — validate / check_permissions / execute
    * `FileGlob.UI`         — render callbacks for the Rust TUI
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.FileGlob.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["glob", "find_files"]

  @impl true
  def search_hint, do: "find files by glob pattern on local filesystem"

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
        "pattern" => %{
          "type" => "string",
          "description" => "Glob pattern (e.g. '**/*.ex', 'lib/**/*.ex')"
        },
        "path" => %{
          "type" => "string",
          "description" => "Base directory to search in (default: current directory)"
        }
      },
      "required" => ["pattern"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # file_glob is on the hot path — the model reaches for it whenever
  # it needs to discover files before reading or editing.
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
  # Glob can return many paths; 50_000 chars gives headroom for ~500 paths
  # at average 100 chars each. Mirrors max_results: 200 cap in Handler.
  def max_result_size_chars, do: 50_000

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
  def to_classifier_input(%{"pattern" => p} = input),
    do: %{pattern: p, path: input["path"]}

  def to_classifier_input(_), do: ""
end
