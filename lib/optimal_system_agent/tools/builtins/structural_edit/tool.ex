defmodule OptimalSystemAgent.Tools.Builtins.StructuralEdit.Tool do
  @moduledoc """
  Structured-layout tool implementation for `structural_edit` (H1: a safe
  structural / multi-file edit tool).

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `StructuralEdit.Constants` — exported atoms for cross-tool reference
    * `StructuralEdit.Prompt`    — dynamic prompt builder
    * `StructuralEdit.Handler`   — validate / check_permissions / execute
    * `StructuralEdit.UI`        — render callbacks for the Rust TUI

  ## Why this tool exists

  A model asked to "rename X to Y in these 6 files" or "change this exact
  snippet everywhere" has, until now, had two options: `multi_file_edit`
  (safe, but requires spelling out the same `old_string`/`new_string` once per
  file — tedious and a place for copy/paste drift to creep in across a large
  batch) or a shell regex sweep (`sed`/`python -c` across files — no
  anchor-uniqueness guarantee, no per-file report, and the thing that broke
  four auth files in one live run). `structural_edit` adds the missing middle:
  a single anchored `pattern` replicated across a file SET, matched with the
  same exact/fuzzy cascade `file_edit` uses, applied all-or-reports.

  ## Return contract

  `execute/2` returns the rich 3-tuple on success:

      {:ok, summary_string, %{results: [%{path: _, lines_changed: _}], count: integer()}}

  mirroring `MultiFileEdit.Handler`'s pattern.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.StructuralEdit.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["safe_multi_edit", "rename_across_files", "pattern_edit"]

  @impl true
  def search_hint,
    do:
      "safely rename or replace an exact anchored snippet across a set of files as one " <>
        "atomic, per-file-reported operation instead of a regex sweep"

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
        "edits" => %{
          "type" => "array",
          "description" =>
            "Heterogeneous edits: each entry names its own path, old_string, new_string. " <>
              "Use this when the replacement genuinely differs per file; use `pattern` " <>
              "instead when the SAME old_string -> new_string applies to every target.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "File path; relative resolves to ~/.osa/workspace/"
              },
              "old_string" => %{
                "type" => "string",
                "description" => "Exact text to find — must match exactly once in this file"
              },
              "new_string" => %{
                "type" => "string",
                "description" => "Replacement text"
              }
            },
            "required" => ["path", "old_string", "new_string"]
          }
        },
        "pattern" => %{
          "type" => "object",
          "description" =>
            "Structured op: apply ONE old_string -> new_string to every file in `paths`, as a " <>
              "single set — for 'rename X to Y in these files' or 'change this exact snippet " <>
              "everywhere'. Say the intent once instead of repeating identical " <>
              "old_string/new_string per file in `edits`.",
          "properties" => %{
            "old_string" => %{
              "type" => "string",
              "description" => "Exact anchor text — must match exactly once in EACH file in paths"
            },
            "new_string" => %{
              "type" => "string",
              "description" => "Replacement text, applied to every file"
            },
            "paths" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Every file this same edit applies to"
            }
          },
          "required" => ["old_string", "new_string", "paths"]
        },
        "verify" => %{
          "type" => "boolean",
          "default" => false,
          "description" =>
            "After a successful apply, run a fast in-process syntax/format check on every " <>
              "touched file and report any problems found. Advisory only — a successful " <>
              "apply is never rolled back because of it."
        }
      },
      "required" => []
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  def should_defer?, do: false

  @impl true
  def always_load?, do: true

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Concurrent edits to overlapping files would produce lost-updates.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: false

  @impl true
  # Modifies multiple files — classified as destructive.
  def destructive?(_input, _ctx), do: true

  @impl true
  def open_world?(_input, _ctx), do: false

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
  def to_classifier_input(input) when is_map(input) do
    paths = Handler.all_target_paths(input)
    %{paths: paths, count: length(paths)}
  end

  def to_classifier_input(_), do: ""
end
