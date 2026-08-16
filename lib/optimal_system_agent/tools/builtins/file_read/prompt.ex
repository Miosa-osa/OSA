defmodule OptimalSystemAgent.Tools.Builtins.FileRead.Prompt do
  @moduledoc """
  Dynamic prompt for `file_read`.

  The prompt body is a function
  (not a static string) so it can reference *current* tool names — when
  `file_grep` is renamed, this prompt updates automatically through the
  `safe_ref/3` helper.

  Read-before-edit, never-re-read-after-edit and batch-your-reads are stated
  once in SYSTEM.md §2 and are deliberately absent here; the windowing and
  already-sent-lines mechanics live on the `offset`, `limit` and `resend`
  parameters. What is left is the one thing that must be said at THIS
  affordance, because this tool is the wrong move being competed with: a
  question about a file is not a reason to read the file.
  """

  @doc """
  Render the file_read tool prompt.

  `opts` is currently unused but reserved for future signal-aware
  customization (e.g., omit image instructions when the model is text-only).
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    grep_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileGrep.Constants, :tool_name, "file_grep")

    dir_list_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.DirList.Constants, :tool_name, "dir_list")

    transform_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.FileTransform.Constants,
        :tool_name,
        "file_transform"
      )

    """
    Reads a file from the local filesystem. `path` must be absolute. Reads the
    full file by default; `offset`/`limit` window a large one. Reads images as
    base64 for vision analysis. Files only — use `#{dir_list_name}` for
    directories.

    Every result ends with `(End of file — N lines total)` or `(Showing lines
    A-B. Use offset=C to continue.)`, so never read again just to find out
    whether you have the whole file.

    Do NOT read a file to answer a question ABOUT it — for *does it contain X*,
    *how many Y*, *is it well-formed* or *did my edit land*, use
    `#{transform_name}`'s `count` or `assert_balanced`, `#{grep_name}`, or a
    one-line `shell_execute` script. This is the single most expensive habit
    available to you: the answer is one line and the file is not.
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
