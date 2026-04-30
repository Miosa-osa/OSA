defmodule OptimalSystemAgent.Tools.Builtins.NotebookEdit.Prompt do
  @moduledoc """
  Dynamic prompt for `notebook_edit`.

  The prompt body is a function (not a static string) so it can reference
  *current* tool names — when `file_read` is renamed, this prompt updates
  automatically through the `safe_ref/3` helper.
  """

  @doc """
  Render the notebook_edit tool prompt.

  `opts` is currently unused but reserved for future signal-aware
  customization (e.g., omit cell-type instructions for text-only models).
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    """
    Read and edit Jupyter notebooks (.ipynb files).

    IMPORTANT: Use `#{file_read_name}` to inspect a notebook's raw JSON before
    editing — the cell array index you pass to `edit_cell`, `delete_cell`, and
    `move_cell` must match the cell's current position in the notebook.

    ## Actions

    ### read
    Return all cells with their type, index, source, and a short output summary.
    Required: `path`.

    ### add_cell
    Append or insert a new cell.
    Required: `path`, `source`.
    Optional: `cell_type` (default: "code"), `position` (0-based; defaults to end).

    ### edit_cell
    Replace the source (and optionally cell_type) of an existing cell.
    Required: `path`, `index`, `source`.
    Optional: `cell_type`.

    ### delete_cell
    Remove a cell by index. Cannot be undone — confirm the index with `read` first.
    Required: `path`, `index`.

    ### move_cell
    Reposition a cell within the notebook.
    Required: `path`, `index` (current position), `position` (target position).

    ## Notes
    - `path` must be an absolute path ending in `.ipynb`.
    - Cell indices are 0-based.
    - Notebook JSON is preserved as-is — unknown top-level fields are never dropped.
    - `outputs` and `execution_count` on existing cells are untouched by `edit_cell`.
    """
  end

  # Lazy cross-tool name reference. If the target tool's Constants module
  # exists and exports the requested function, use the live value; otherwise
  # fall back to a literal default. Mirrors the lazy-require pattern in
  # FileRead.Prompt.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
