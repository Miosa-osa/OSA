defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Prompt do
  @moduledoc """
  Dynamic prompt for `file_read`.

 The prompt body is a function
  (not a static string) so it can reference *current* tool names — when
  `file_edit` is renamed, this prompt updates automatically through the
  `safe_ref/3` helper.
  """

  @doc """
  Render the file_read tool prompt.

  `opts` is currently unused but reserved for future signal-aware
  customization (e.g., omit image instructions when the model is text-only).
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    edit_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileEdit.Constants, :tool_name, "file_edit")

    write_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileWrite.Constants, :tool_name, "file_write")

    dir_list_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.DirList.Constants, :tool_name, "dir_list")

    """
    Reads a file from the local filesystem.

    Usage:
    - The path parameter must be an absolute path, not a relative path.
    - By default, reads the full file. Use `offset` and `limit` for large files.
    - This tool can read images (PNG, JPG, GIF, WEBP) — returns base64 for vision analysis.
    - This tool can only read files, not directories. Use `#{dir_list_name}` for directories.
    - If you read a file that exists but has empty contents you will receive a warning.
    - ALWAYS read a file with this tool before editing it with `#{edit_name}` or `#{write_name}`.
    """
  end

  # Lazy cross-tool name reference. If the target tool's Constants module
  # exists and exports the requested function, use the live value;
  # otherwise fall back to a literal default. Mirrors the lazy-require
  # pattern at upstream.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
