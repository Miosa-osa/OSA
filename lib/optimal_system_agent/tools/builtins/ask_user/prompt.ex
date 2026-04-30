defmodule OptimalSystemAgent.Tools.Builtins.AskUser.Prompt do
  @moduledoc """
  Dynamic prompt for `ask_user`.

 The prompt body is
  a function so it can reference the current exit-plan-mode tool name
  via `safe_ref/3`.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    exit_plan_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.ExitPlanMode.Constants,
        :tool_name,
        "exit_plan_mode"
      )

    """
    Use this tool when you need to ask the user questions during execution. This allows you to:
    1. Gather user preferences or requirements
    2. Clarify ambiguous instructions
    3. Get decisions on implementation choices as you work
    4. Offer choices to the user about what direction to take.

    Usage notes:
    - Users will always be able to provide free-text input.
    - Use the optional `options` list to present multiple-choice answers.
    - If you recommend a specific option, make that the first option.

    Plan mode note: In plan mode, use this tool to clarify requirements or choose between
    approaches BEFORE finalising your plan. Do NOT use this tool to ask "Is my plan ready?"
    or "Should I proceed?" — use #{exit_plan_name} for plan approval.
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
