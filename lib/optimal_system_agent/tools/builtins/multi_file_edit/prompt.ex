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
    Apply exact-string edits across multiple files atomically: all are validated
    before any file is touched, so all succeed or none apply.

    - ALWAYS read each file with `#{file_read_name}` before editing it.
    - For single-file edits prefer `#{file_edit_name}`.
    - Relative paths resolve to ~/.osa/workspace/.
    - Do NOT re-read to verify successful edits — this tool errors when any edit does not apply, and nothing is written then.
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
