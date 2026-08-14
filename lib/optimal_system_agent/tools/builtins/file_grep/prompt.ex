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
    Search file contents for a regex pattern. ALWAYS use file_grep for content
    search — NEVER #{shell_name} with grep or rg. Supports full regex syntax
    (e.g. "log.*Error", "function\\\\s+\\\\w+").

    Independent searches belong in the same turn: fire every pattern you already
    know you need as parallel calls rather than one per turn.
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
