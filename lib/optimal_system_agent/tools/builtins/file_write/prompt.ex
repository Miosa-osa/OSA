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
    transform_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.FileTransform.Constants,
        :tool_name,
        "file_transform"
      )

    edit_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileEdit.Constants, :tool_name, "file_edit")

    """
    Writes a file to the local filesystem, overwriting any file already at that
    path.

    Prefer `#{edit_name}` or `#{transform_name}` for modifying an existing file;
    use this only for a genuinely new file or a full rewrite. Never clobber a
    file to change a few lines.
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
