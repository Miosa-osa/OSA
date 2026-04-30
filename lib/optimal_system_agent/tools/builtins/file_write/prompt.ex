defmodule OptimalSystemAgent.Tools.Builtins.FileWrite.Prompt do
  @moduledoc """
  Dynamic prompt for `file_write`.

  The prompt is a function (not a static string) so it can reference
  current tool names for `file_read` and `file_edit` via `safe_ref/3`.
  When either of those tools is renamed, this prompt updates automatically.
  """

  @doc """
  Render the file_write tool prompt.

  `opts` is reserved for future signal-aware customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    edit_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileEdit.Constants, :tool_name, "file_edit")

    """
    Writes a file to the local filesystem.

    Usage:
    - This tool will overwrite the existing file if there is one at the provided path.
    - If this is an existing file, you MUST use `#{read_name}` first to read the file's contents. This tool will fail if you did not read the file first.
    - Prefer `#{edit_name}` for modifying existing files — it only sends the diff. Only use this tool to create new files or for complete rewrites.
    - NEVER create documentation files (*.md) or README files unless explicitly requested by the user.
    - Only use emojis if the user explicitly requests it. Avoid writing emojis to files unless asked.
    - Relative paths resolve to ~/.osa/workspace/. Absolute paths and ~ paths also accepted.
    """
  end

  # Lazy cross-tool name reference. If the target tool's Constants module
  # exists and exports the requested function, use the live value;
  # otherwise fall back to a literal default. Mirrors the lazy-require
  # pattern from `FileRead.Prompt`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
