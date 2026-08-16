defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit.Prompt do
  @moduledoc """
  Dynamic prompt for `multi_file_edit`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_edit_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileEdit.Constants, :tool_name, "file_edit")

    """
    Apply exact-string edits across multiple files atomically: all are validated
    before any file is touched, so all succeed or none apply. For single-file
    edits prefer `#{file_edit_name}`.
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
