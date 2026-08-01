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
    - Ask ONE question per call, phrased as a single short sentence. Keep it concrete —
      the user is mid-task and should be able to answer at a glance.
    - Use the optional `options` list to present multiple-choice answers. Provide 2-4
      mutually exclusive choices — not more.
    - Put the option you recommend FIRST and suffix its label with "(Recommended)".
    - Give each option a SHORT label (a few words, it is rendered in a fixed column)
      followed by one line explaining the tradeoff of choosing it, e.g.
      "Rewrite the parser (Recommended) — slower to build but removes the whole class
      of escaping bugs."
    - Do NOT add an "Other", "Something else" or "None of these" option. The client
      always renders a free-text row, so a catch-all option only wastes a slot.
    - Optional `header`: at most 12 characters categorising the question ("parser",
      "styling", "deploy"). It renders as a small chip; omit it if nothing fits.

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
