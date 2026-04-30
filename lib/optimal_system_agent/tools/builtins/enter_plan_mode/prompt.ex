defmodule OptimalSystemAgent.Tools.Builtins.EnterPlanMode.Prompt do
  @moduledoc """
  Dynamic prompt for the `enter_plan_mode` tool.
  """

  def render(_opts \\ []) do
    """
    Voluntarily restrict this session to read-only operations while you think through
    a complex task. Call this before exploring code, reading files, and forming a plan.

    While plan mode is active:
    - Write, destructive, and shell-mutation tools are blocked at the permission layer.
    - Read-only tools (file_read, grep, web_fetch, etc.) remain available.
    - You can still reason freely and call read-only tools to gather context.

    When your plan is complete and you are ready to execute, call `exit_plan_mode`
    with a summary of the plan. Execution tools are restored at that point.

    Use this when:
    - A task has 3+ steps or involves architectural decisions.
    - You want to verify your understanding before making any changes.
    - You need to explore an unfamiliar codebase before acting.

    Do NOT call this if you are already in plan mode — it is idempotent but
    will replace any prior pre-entry state with the current mode.
    """
  end
end
