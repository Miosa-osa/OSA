defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Prompt do
  @moduledoc """
  Dynamic prompt for `file_glob`.

  References `file_read` and `shell_execute` by live name so renames
  propagate automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    """
    Fast file pattern matching at any codebase size, e.g. "**/*.js" or
    "src/**/*.ts". Returns matching paths sorted alphabetically, directories
    suffixed with `/`. Dotfiles and dot-directories ARE matched, so no separate
    `.*` pattern is needed; `.git/` contents are omitted unless the pattern names
    `.git`. A `path` that does not exist is reported as such, never as "no
    matches". Read the matches with #{read_name}.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
