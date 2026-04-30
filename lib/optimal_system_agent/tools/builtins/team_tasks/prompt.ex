defmodule OptimalSystemAgent.Tools.Builtins.TeamTasks.Prompt do
  @moduledoc """
  Dynamic prompt for `team_tasks`.

  References `message_agent` by its live `Constants.tool_name/0` so a rename
  propagates here automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    message_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.MessageAgent.Constants,
        :tool_name,
        "message_agent"
      )

    """
    View and manage the shared team task list.

    Agents use this tool to coordinate parallel work: see what tasks exist, check status,
    claim pending work, and mark their own tasks complete. The task list is shared across
    all agents in a team via ETS.

    Actions:
    - `list`             — view all tasks with status, assignees, and dependencies
    - `claim`            — take ownership of a pending task (blocked by unmet dependencies)
    - `complete`         — mark your claimed task done, optionally with a result summary
    - `scratchpad_write` — persist notes visible to all teammates
    - `scratchpad_read`  — read all teammate scratchpad entries

    Coordination tips:
    - Always `list` before claiming to pick the highest-priority unblocked task.
    - Use `#{message_name}` to send results or ask teammates questions directly.
    - Tasks with unmet dependencies cannot be claimed — complete blockers first.
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
