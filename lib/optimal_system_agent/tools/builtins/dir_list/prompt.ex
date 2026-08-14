defmodule OptimalSystemAgent.Tools.Builtins.DirList.Prompt do
  @moduledoc """
  Dynamic prompt for `dir_list`.

  Cross-references `file_read` and `file_glob` by name so renames propagate
  automatically through the `safe_ref/3` helper, mirroring the lazy-require
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
    Lists files and directories at an absolute path (omit or pass "." for the
    cwd). Does not recurse. Output is a `<directory> — <n> entries` header, then
    one `<type>\\t<size>\\t<name>` line per entry (type `dir`/`file`/raw fs type;
    size B/K/M, `-` for directories). Dotfiles are included; an empty directory
    reports itself rather than returning empty. Use `#{file_read_name}` for a
    file, `#{file_glob_name}` for a pattern.
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
