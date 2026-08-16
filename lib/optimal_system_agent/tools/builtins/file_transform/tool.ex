defmodule OptimalSystemAgent.Tools.Builtins.FileTransform.Tool do
  @moduledoc """
  `file_transform` — change a file without quoting it.

  Declarations only; logic lives in the sibling modules:

    * `FileTransform.Constants` — exported name for cross-tool reference
    * `FileTransform.Prompt`    — description, with worked examples
    * `FileTransform.Ops`       — the transform vocabulary (pure)
    * `FileTransform.Handler`   — validate / check_permissions / execute
    * `FileTransform.UI`        — render callbacks for the Rust TUI

  See `docs/design/context-free-edits.md` for why this exists and what was
  rejected on the way to it.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.FileTransform.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["transform_file"]

  @impl true
  def search_hint,
    do: "change a file by describing the change, without reading it into context"

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
          "description" =>
            "The one file this call may modify. Nothing else is touched. " <>
              "Relative paths root at ~/.osa/workspace/."
        },
        "operations" => %{
          "type" => "array",
          "description" =>
            "Ordered operations, applied in memory and committed together. If any one " <>
              "fails its expectation, nothing is written.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "op" => %{
                "type" => "string",
                "description" =>
                  "replace | replace_regex | delete_matching_lines | insert_after | " <>
                    "insert_before | append | prepend | count | assert_balanced. " <>
                    "`count` and `assert_balanced` change nothing and return one line " <>
                    "whether the file is 50 lines or 5,000 — use them to answer a " <>
                    "question about the file instead of reading it, and to re-check " <>
                    "structure after each change."
              },
              "find" => %{"type" => "string", "description" => "replace: literal text to find"},
              "pattern" => %{
                "type" => "string",
                "description" => "Regex anchor, for the regex and line operations"
              },
              "to" => %{
                "type" => "string",
                "description" => "Replacement text. Use \\1 for regex capture groups."
              },
              "text" => %{
                "type" => "string",
                "description" => "Text to insert, append or prepend"
              },
              "expect" => %{
                "type" => "integer",
                "description" =>
                  "Exact number of matches required. OPTIONAL — omit it unless you " <>
                    "actually know the count, and omitting it requires at least one, " <>
                    "which is the guard that makes an unread file safe to edit. Set it " <>
                    "when the count is the point. A mismatch aborts the whole transform " <>
                    "without writing and reports the count it found; re-issue the same " <>
                    "call with that count rather than switching tools."
              },
              "open" => %{"type" => "string", "description" => "assert_balanced: opener, e.g. ("},
              "close" => %{"type" => "string", "description" => "assert_balanced: closer, e.g. )"}
            },
            "required" => ["op"]
          }
        },
        "dry_run" => %{
          "type" => "boolean",
          "description" =>
            "Report what the operations would do and write nothing. Use to check an " <>
              "anchor before committing to it."
        }
      },
      "required" => ["path", "operations"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  # A tool the model never sees is worth nothing, and this one competes directly
  # with file_edit — which is always loaded. It has to be in the same prompt.
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  # A dry run reads and reports; a real run mutates. The distinction is real and
  # the loop uses it to decide what may run in parallel.
  def read_only?(input, _ctx), do: Map.get(input, "dry_run") == true

  @impl true
  # Anchored and atomic, but it still overwrites bytes in place.
  def destructive?(input, _ctx), do: Map.get(input, "dry_run") != true

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  # The result is O(operations); 30k is the same ceiling the other write tools
  # carry and this one has no realistic way to approach it.
  def max_result_size_chars, do: 30_000

  # ── Flat-layout compatibility ─────────────────────────────────────────
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
