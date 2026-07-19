defmodule OptimalSystemAgent.Tools.Builtins.ExitPlanMode.Prompt do
  @moduledoc """
  Dynamic prompt for the `exit_plan_mode` tool.
  """

  def render(_opts \\ []) do
    """
    Exit plan mode and restore full execution permissions. Call this when you
    have finished investigating and are ready to hand your plan to the user
    for approval.

    Provide a `plan` argument with your full plan text (goal, steps, files,
    risks, estimate — same structure as a plan-mode turn). This is NOT just
    logged: it is written to the session's durable plan file and submitted
    through the same approve/reject/edit round-trip a user-toggled plan-mode
    turn uses — the user reviews and approves it before any execution
    resumes, exactly like `EnterPlanMode`/`ExitPlanMode` in Claude Code.

    For research tasks that involve reading files, searching, or exploring
    the codebase to understand the current state: keep investigating with
    read-only tools and do NOT call this until your plan is actually grounded
    in what the code does — call it only once you are ready for approval, not
    mid-investigation.

    After this call:
    - Write, destructive, and shell-mutation tools are unblocked.
    - The session returns to its previous permission mode.
    - If `plan` was provided, execution PAUSES pending the user's approval —
      do not treat this call as permission to start executing.

    If called while not in plan mode, the call is a no-op and returns a
    diagnostic message — no error is raised.
    """
  end
end
