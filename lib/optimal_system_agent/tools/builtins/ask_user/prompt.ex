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
    Ask the user ONE question mid-task and wait for the answer — to clarify an
    ambiguous instruction, gather a preference, or choose a direction. Phrase it
    as a single short sentence.

    Use `options` for 2-4 mutually exclusive choices, the recommended one FIRST
    with a "(Recommended)" suffix, each a SHORT label plus one line on its
    tradeoff. Never add an "Other"/"None of these" option — the client always
    renders a free-text row. In plan mode use this to settle requirements, never
    to ask whether to proceed — #{exit_plan_name} handles plan approval.
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
