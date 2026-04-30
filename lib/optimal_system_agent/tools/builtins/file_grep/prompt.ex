defmodule OptimalSystemAgent.Tools.Builtins.FileGrep.Prompt do
  @moduledoc """
  Dynamic prompt for `file_grep`.

  Follows the `safe_ref/3` pattern from `FileRead.Prompt` — tool name
  references are resolved at runtime so renames propagate automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    shell_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants,
        :tool_name,
        "shell_execute"
      )

    """
    Search file contents for a regex pattern.

    Usage:
    - ALWAYS use file_grep for content search. NEVER use #{shell_name} with grep or rg.
    - Supports full regex syntax (e.g., "log.*Error", "function\\\\s+\\\\w+")
    - Filter files with glob parameter (e.g., "*.js", "**/*.tsx")
    - Output modes: 'content' shows matching lines, 'files' shows only file paths (default), 'count' shows match counts
    - Use context parameter to see surrounding code lines
    """
  end

  # Lazy cross-tool name reference. If the target tool's Constants module
  # exists and exports the requested function, use the live value;
  # otherwise fall back to a literal default. Mirrors the lazy-require
  # pattern at `src/tools/ToolSearchTool/prompt.ts:9-19`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
