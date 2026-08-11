defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit.Tool do
  @moduledoc """
  Structured-layout tool implementation for `notebook_edit`.

  Per-tool directory layout — declarations only, all logic lives in the
  sibling modules:

    * `NotebookEdit.Constants`  — exported atoms for cross-tool reference
    * `NotebookEdit.Prompt`     — dynamic prompt builder (cross-refs file_read by name)
    * `NotebookEdit.Handler`    — validate / check_permissions / execute
    * `NotebookEdit.UI`         — render callbacks for the Rust TUI

  ## Return contract
  `execute/2` returns:
    * `{:ok, result_string, %{cell_count: n, path: expanded}}` for the `read` action.
    * `{:ok, result_string}` for all mutating actions.
  Both shapes are specified by `OptimalSystemAgent.Tools.Behaviour.tool_output/0`.

  ## Callback values
    * `should_defer?`       → true  (notebook edit is not always needed)
    * `always_load?`        → false
    * `concurrency_safe?`   → false (writes serialize to a single file)
    * `read_only?`          → true  for `action == "read"`, false otherwise
    * `destructive?`        → true  for `action == "delete_cell"`, false otherwise
    * `safety`              → `:write_safe`
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.NotebookEdit.{Constants, Handler, Prompt, UI}

  # ── Identity ──────────────────────────────────────────────────────────
  @impl true
  def name, do: Constants.tool_name()

  @impl true
  def aliases, do: ["notebook_read", "edit_notebook"]

  @impl true
  def search_hint, do: "read and edit Jupyter notebook (.ipynb) cells"

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
        "action" => %{
          "type" => "string",
          "enum" => Constants.actions(),
          "description" => "Action to perform on the notebook"
        },
        "path" => %{
          "type" => "string",
          "description" => "Absolute path to the .ipynb file"
        },
        "index" => %{
          "type" => "integer",
          "description" => "Cell index (0-based) — required for edit_cell, delete_cell, move_cell"
        },
        "cell_type" => %{
          "type" => "string",
          "enum" => ["code", "markdown"],
          "description" =>
            "Cell type — required for add_cell, optional for edit_cell (default: code)"
        },
        "source" => %{
          "type" => "string",
          "description" => "Cell source content — required for add_cell, edit_cell"
        },
        "position" => %{
          "type" => "integer",
          "description" =>
            "Target position (0-based) — required for move_cell; optional for add_cell (defaults to end)"
        }
      },
      "required" => ["action", "path"]
    }
  end

  # ── Loading semantics ─────────────────────────────────────────────────
  @impl true
  # Notebook editing is not always needed — defer until the model calls it.
  def should_defer?, do: true

  @impl true
  def always_load?, do: false

  # ── Execution semantics (per-input) ───────────────────────────────────
  @impl true
  # Two concurrent writes to the same notebook would produce a lost-update.
  # BEAM process isolation does not help here because File.write is external state.
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(%{"action" => "read"}, _ctx), do: true
  def read_only?(_input, _ctx), do: false

  @impl true
  # delete_cell permanently removes a cell — treat as destructive.
  def destructive?(%{"action" => "delete_cell"}, _ctx), do: true
  def destructive?(_input, _ctx), do: false

  @impl true
  def open_world?(_input, _ctx), do: false

  @impl true
  def max_result_size_chars, do: 30_000

  # ── Flat-layout compatibility ──────────────────────────────────────────
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
  def to_classifier_input(%{"action" => a, "path" => p}), do: %{action: a, path: p}
  def to_classifier_input(_), do: ""
end
