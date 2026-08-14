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
    full file by default; use `offset` and `limit` for large files. Reads images
    (PNG, JPG, GIF, WEBP) as base64 for vision analysis. Files only — use
    `#{dir_list_name}` for directories. A file that exists but is empty returns a
    warning.

    Every result ends with either `(End of file — N lines total)` or
    `(Showing lines A-B. Use offset=C to continue.)`, so you never have to read
    again to find out whether you have the whole file. If you need more than the
    window gave you, continue from the offset it names or ask for a larger
    `limit` — do not walk the file in small overlapping slices. Reading several
    different files is independent work: issue those calls in parallel in one
    turn.

    A line too wide to return whole is clamped, and the notice names the
    `byte_offset` that continues it — bytes are a second axis, and the only one
    that can reach the rest of a line `limit` already selected in full.

    Do NOT read a file to answer a question ABOUT it. For *does it contain X*,
    *how many Y*, or *is it well-formed*, use `#{transform_name}`'s `count` or
    `assert_balanced`, or a one-line `shell_execute` script: the answer costs its
    own size, and reading the file costs the file.

    Read a file once before your FIRST `#{edit_name}` or `#{write_name}` to it.
    Do not re-read it after your own successful edit — you know what you
    changed, and if anything else changes the file, the next edit is rejected
    with a stale-view error rather than silently landing.
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
