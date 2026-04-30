defmodule OptimalSystemAgent.Tools.Builtins.CreateSkill.Prompt do
  @moduledoc """
  Dynamic prompt for `create_skill`.

  Kept as a function so cross-tool name references stay live — if
  `list_skills` is renamed, the mention here updates automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    list_name =
      safe_ref(OptimalSystemAgent.Tools.Builtins.ListSkills.Constants, :tool_name, "list_skills")

    """
    Create a reusable skill document.

    Skills load automatically when their trigger matches the current task,
    helping perform similar tasks faster in the future.

    - `name` must be kebab-case (e.g. 'express-api-testing')
    - `trigger` is a keyword/regex string matched against task descriptions
    - Use `#{list_name}` to see all existing skills before creating duplicates
    - Skills are stored in the configured skills directory (default: ~/.osa/skills)
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
