defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Prompt do
  @moduledoc """
  Dynamic prompt for `multi_file_edit`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_edit_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileEdit.Constants, :tool_name, "file_edit")

    file_read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    """
    Apply edits across multiple files atomically. All edits succeed or none are applied.

    Usage:
    - Provide a list of edits, each with `path`, `old_string`, and `new_string`.
    - Validation runs on all edits before any file is touched — atomic guarantee.
    - Relative paths resolve to ~/.osa/workspace/.
    - ALWAYS use `#{file_read_name}` to read each file before editing.
    - For single-file edits prefer `#{file_edit_name}`.
    - Do NOT re-read the files to verify edits that succeeded. This tool errors when any edit does not apply, and nothing is written in that case.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
