defmodule OptimalSystemAgent.Tools.Builtins.EnterPlanMode.Prompt do
  @moduledoc """
  Dynamic prompt for the `enter_plan_mode` tool.
  """

  def render(_opts \\ []) do
    """
    Restrict this session to read-only operations while you investigate and form
    a plan. Use it when a task has 3+ steps, involves architectural decisions, or
    means exploring an unfamiliar codebase first.

    Write, destructive, and shell-mutation tools are blocked at the permission
    layer; read-only tools stay available. Call `exit_plan_mode` with the full
    plan text when ready — execution then waits for the user's approval.
    Idempotent; do not call it when already in plan mode.
    """
  end
end
