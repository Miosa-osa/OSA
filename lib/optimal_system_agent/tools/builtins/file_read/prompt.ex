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
    whether you have the whole file. If you need more, continue from the offset
    it names or ask for a larger `limit` — do not walk a file in small
    overlapping slices. Reading several different files is independent work:
    issue those calls in parallel in one turn.

    Lines already shown to you this session are not sent twice, so a result that
    names the lines it left out is the rest of what you asked for, not a
    truncation; pass `resend: true` if you no longer have the earlier result. An
    over-wide line is clamped and the notice names the `byte_offset` continuing
    it.

    Do NOT read a file to answer a question ABOUT it — for *does it contain X*,
    *how many Y* or *is it well-formed*, use `#{transform_name}`'s `count` or
    `assert_balanced`, or a one-line `shell_execute` script.

    Read a file once before your FIRST `#{edit_name}` or `#{write_name}` to it,
    and never re-read it after your own successful edit — an edit against a stale
    view is rejected, not silently landed.
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
