defmodule OptimalSystemAgent.Tools.Builtins.FileEdit.Prompt do
  @moduledoc """
  Dynamic prompt for `file_edit`.

  Mirrors `src/tools/FileEditTool/prompt.ts`. The prompt body is a function
  (not a static string) so it can reference *current* tool names — when
  `file_read` is renamed, this prompt updates automatically through the
  `safe_ref/3` helper.

  The word "surgical" appears in the first line to satisfy the the contract
  (the test suite asserts `description() =~ "surgical"`).
  """

  @doc """
  Render the file_edit tool prompt.

  `opts` is currently unused but reserved for future signal-aware
  customization.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    read_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.FileRead.Constants,
        :tool_name,
        "file_read"
      )

    """
    Performs surgical exact-string replacements in files.

    Usage:
    - You must use `#{read_name}` at least once before editing. This tool will error if you attempt an edit without reading the file.
    - When editing text, ensure you preserve the exact indentation (tabs/spaces) as it appears in the file.
    - ALWAYS prefer editing existing files. NEVER write new files unless explicitly required.
    - The edit will FAIL if `old_string` is not unique in the file. Provide a larger string with more surrounding context to make it unique, or use `replace_all` to change every instance.
    - Use `replace_all` for renaming strings across the file (e.g., renaming a variable).
    - Only use emojis if the user explicitly requests it.
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
