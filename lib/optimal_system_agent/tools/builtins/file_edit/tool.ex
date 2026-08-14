defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.Tool do
  @moduledoc """
  Structured-layout tool implementation for `file_edit`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `FileEdit.Constants`  — exported atoms for cross-tool reference
    * `FileEdit.Prompt`     — dynamic prompt builder (references FileRead by name)
    * `FileEdit.Handler`    — validate / check_permissions / execute
    * `FileEdit.UI`         — render callbacks for the Rust TUI

  ## Return contract
  `execute/2` preserves the the rich 3-tuple on success:
    `{:ok, result_string, %{diff: diff_text, stats: diff_stats, path: resolved}}`

  The 2-tuple `{:ok, result_string}` is returned only when the diff is empty.
  Both shapes are specified by `OptimalSystemAgent.Tools.Behaviour.tool_output/0`.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["edit", "edit_file"]

  @impl true
  def search_hint, do: "perform exact string replacements in files"

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
        "path" => %{
          "type" => "string",
          "description" => "Absolute path to the file"
        },
        "old_string" => %{
          "type" => "string",
          "description" => "Exact text to find; unique unless replace_all"
        },
        "new_string" => %{
          "type" => "string",
          "description" => "Replacement text"
        },
        "replace_all" => %{
          "type" => "boolean",
          "description" => "Replace all occurrences (default false)"
        }
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # file_edit must always be in the prompt — the model's system prompt
  # says "ALWAYS read before editing" and a missing tool definition would
  # silently break that instruction.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Two concurrent edits to the same file would produce a lost-update. BEAM
  # process isolation doesn't help here because File.write! is external state.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: true

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: 30_000

  # ── Flat-layout compatibility ──────────────────────────────────────────────────
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
  def to_classifier_input(%{"path" => p}), do: %{path: p}
  def to_classifier_input(_), do: ""
end
