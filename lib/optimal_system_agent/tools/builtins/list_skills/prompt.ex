defmodule OptimalSystemAgent.Tools.Builtins.ListSkills.Prompt do
  @moduledoc """
  Dynamic prompt for `list_skills`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    create_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.CreateSkill.Constants,
        :tool_name,
        "create_skill"
      )

    """
    List all available skills with their descriptions and triggers.

    - Returns every skill found in the configured skills directory
    - Use this before `#{create_name}` to avoid creating duplicates
    - Skills with matching triggers load automatically into context
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
