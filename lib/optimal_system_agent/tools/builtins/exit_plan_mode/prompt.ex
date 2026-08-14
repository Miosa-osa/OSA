defmodule OptimalSystemAgent.Tools.Builtins.ExitPlanMode.Prompt do
  @moduledoc """
  Dynamic prompt for the `exit_plan_mode` tool.
  """

  def render(_opts \\ []) do
    """
    Exit plan mode and hand your plan to the user for approval. Call it only
    once your plan is grounded in what the code actually does — keep
    investigating with read-only tools until then, never mid-investigation.

    Pass the full plan text in `plan` (goal, steps, files, risks). Write,
    destructive, and shell-mutation tools are unblocked, but execution PAUSES
    pending the user's approval — this call is not permission to start
    executing. A no-op if not in plan mode.
    """
  end
end
