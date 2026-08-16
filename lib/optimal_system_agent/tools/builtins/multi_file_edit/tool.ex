defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Tool do
  @moduledoc """
  Structured-layout tool implementation for `multi_file_edit`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `MultiFileEdit.Constants`  — exported atoms for cross-tool reference
    * `MultiFileEdit.Prompt`     — dynamic prompt builder
    * `MultiFileEdit.Handler`    — validate / check_permissions / execute
    * `MultiFileEdit.UI`         — render callbacks for the Rust TUI

  ## Return contract

  `execute/2` returns the rich 3-tuple on success:

      {:ok, summary_string, %{results: [%{path: _, lines_changed: _}], count: integer()}}

  This mirrors `FileEdit.Handler`'s pattern and lets SSE consumers and the
  Rust TUI surface per-file diff metadata.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.MultiFileEdit.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["multi_edit", "batch_edit"]

  @impl true
  def search_hint, do: "apply exact string replacements across multiple files atomically"

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
            "Edits to apply, each with path, old_string, new_string. Every file named " <>
              "here must have been read this session; the call fails otherwise, and it " <>
              "fails without writing anything when any single edit does not apply — so " <>
              "a success IS the confirmation and needs no read-back.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "File path; relative resolves to ~/.osa/workspace/"
              },
              "old_string" => %{
                "type" => "string",
                "description" => "Exact text to find (first occurrence only)"
              },
              "new_string" => %{
                "type" => "string",
                "description" => "Replacement text"
              }
            },
            "required" => ["path", "old_string", "new_string"]
          }
        }
      },
      "required" => ["edits"]
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
  def to_classifier_input(%{"edits" => edits}) when is_list(edits) do
    paths = Enum.map(edits, fn e -> Map.get(e, "path", "") end)
    %{paths: paths, count: length(edits)}
  end

  def to_classifier_input(_), do: ""
end
