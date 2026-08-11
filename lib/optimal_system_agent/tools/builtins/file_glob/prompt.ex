defmodule OptimalSystemAgent.Tools.Builtins.FileGlob.Prompt do
  @moduledoc """
  Dynamic prompt for `file_glob`.

  References `file_read` and `shell_execute` by live name so renames
  propagate automatically.
  """

  alias OptimalSystemAgent.Tools.Builtins.FileGlob.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    read_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.FileRead.Constants, :tool_name, "file_read")

    shell_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants,
        :tool_name,
        "shell_execute"
      )

    """
    Fast file pattern matching tool that works with any codebase size.

    Usage:
    - Supports glob patterns like "**/*.js" or "src/**/*.ts"
    - Returns matching paths sorted alphabetically; directories are suffixed with `/`
    - Dotfiles and dot-directories ARE matched (`.env.example`, `.github/**`), so you
      never need a separate `.*` pattern to see them
    - Contents of `.git/` are omitted unless your pattern names `.git` explicitly
    - Base directory comes from `path` (default: current directory). A `path` that does
      not exist is reported as such — it is never silently reported as "no matches"
    - Use this tool when you need to find files by name patterns
    - ALWAYS use #{Constants.tool_name()} instead of #{shell_name} with find or ls
    - Combine with #{read_name} to then read matched files
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
