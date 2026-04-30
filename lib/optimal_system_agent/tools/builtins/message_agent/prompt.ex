defmodule OptimalSystemAgent.Tools.Builtins.MessageAgent.Prompt do
  @moduledoc """
  Dynamic prompt for `message_agent`.

  References `team_tasks` by its live `Constants.tool_name/0` so a rename
  propagates here automatically.
  """

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    team_tasks_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TeamTasks.Constants,
        :tool_name,
        "team_tasks"
      )

    """
    Send messages between agents in a team, or read your inbox.

    Enables inter-agent communication via PubSub-backed mailbox. Messages are also
    stored in ETS for later retrieval even if the recipient hasn't polled yet.

    Actions:
    - `send`      — send a message to a specific teammate by session ID
    - `read`      — check your inbox for messages from teammates
    - `broadcast` — send a message to all agents in the team

    Coordination tips:
    - Use `#{team_tasks_name}` to see shared task state (status, assignees, dependencies).
    - `broadcast` is appropriate for announcing a major finding or blocking issue.
    - `send` is preferred for targeted results or questions that only one teammate needs.
    - Check your inbox with `read` before starting work to see if teammates have context for you.
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
