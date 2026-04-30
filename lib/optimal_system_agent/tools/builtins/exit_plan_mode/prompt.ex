defmodule OptimalSystemAgent.Tools.Builtins.ExitPlanMode.Prompt do
  @moduledoc """
  Dynamic prompt for the `exit_plan_mode` tool.
  """

  def render(_opts \\ []) do
    """
    Exit plan mode and restore full execution permissions. Call this when you
    have finished reasoning and are ready to execute your plan.

    Provide a `plan` argument summarising the steps you intend to take. This
    is logged for observability and shown to the user so they can review before
    execution begins.

    After this call:
    - Write, destructive, and shell-mutation tools are unblocked.
    - The session returns to its previous permission mode.

    If called while not in plan mode, the call is a no-op and returns a
    diagnostic message — no error is raised.
    """
  end
end
