defmodule OptimalSystemAgent.Tools.Builtins.DirList.Prompt do
  @moduledoc """
  Dynamic prompt for `dir_list`.

  Cross-references `file_read` and `file_glob` by name so renames propagate
  automatically through the `safe_ref/3` helper, mirroring the lazy-require
  pattern at `src/tools/ToolSearchTool/prompt.ts:9-19`.
  """

  @doc """
  Render the dir_list tool prompt.

  `opts` is reserved for future signal-aware customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    file_read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    file_glob_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileGlob.Constants, :tool_name, "file_glob")

    """
    Lists files and directories at the given path with type and size information.

    Usage:
    - The path parameter must be an absolute path, not a relative path.
    - Omit path (or pass ".") to list the current working directory.
    - Output format per entry: `<type>\\t<size>\\t<name>` where type is `dir`, `file`, or the raw fs type.
    - Sizes use human-readable suffixes (B, K, M); directories always show `-`.
    - To read a specific file use `#{file_read_name}`.
    - To search for files matching a pattern use `#{file_glob_name}`.
    - This tool does not recurse into subdirectories.
    """
  end

  # Lazy cross-tool name reference. If the target Constants module exists and
  # exports the given function, return the live value; otherwise fall back to
  # the provided literal default.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
