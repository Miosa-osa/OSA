defmodule OptimalSystemAgent.Tools.Builtins.Delegate.Prompt do
  @moduledoc """
  Dynamic prompt for the `delegate` tool.

  The description is a function (not a static string) so it can reference
  other tool names via `safe_ref/3` — when `ask_user` is renamed this prompt
  updates automatically, mirroring the lazy-require pattern at

  Kept deliberately short: this string sits in the cached static prefix of
  EVERY request, so anything the parameter schema already states, or that
  §3 of the system prompt already states, does not belong here. In particular
  the briefing rule lives on the `task` parameter and the fan-out rule on
  `tasks`, because that is where the model is composing the value they
  constrain. What is left here is the routing decision and the two things a
  model reliably gets wrong: that a running agent must be left alone, and that
  ending a turn is not a way of waiting for one.

  The second clause is not advice, it is a correction of a false inference this
  prompt used to invite. "A <task-notification> reaches you when it finishes"
  is true, but on its own it reads as "so you may stop and it will find you" —
  and a live v1.0.099 session did exactly that, ending on "Let me wait for the
  explorer… should be any moment now" with five plan items open and the child
  still running. The notification does eventually wake an idle loop
  (`Loop.poke/1`), but the turn the user was watching is over and its plan is
  abandoned. `task_wait` is the only affordance that actually waits, and it was
  never named here, so the model had no correct move available to it. See
  `DelegatedChildIsOutstandingWorkTest`.
  """

  alias OptimalSystemAgent.Tools.Builtins.Delegate.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    ask_user_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.AskUser,
        :name,
        "ask_user"
      )

    task_wait_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.TaskWait.Constants,
        :tool_name,
        "task_wait"
      )

    roles_list = Constants.roles() |> Enum.join(", ")

    """
    Launch a specialized agent to handle a subtask autonomously. Each agent gets \
    its own context window, model, and tool access.

    Use it for work that is parallelizable, needs a specialist role, or needs \
    codebase context fast (role='explore'). Don't use it for single-file tasks, \
    quick reads, or anything needing user interaction (use #{ask_user_name}).

    Roles: #{roles_list}. Omit role for a generic agent.

    Background is the DEFAULT: the call returns an agentId immediately and a \
    <task-notification> reaches you when it finishes. While it runs, do NOT poll \
    task_output, read its output file, or redo its work — just do other work. \
    Continue a finished agent with task_resume or message_agent.

    Ending your turn is NOT waiting. If you cannot proceed without a result, \
    call #{task_wait_name} with its agentId — that is the only way to wait. \
    Never end a turn on "I'll wait for it" or "should be any moment now": say \
    what you have actually verified, or join the agent first.
    """
  end

  # Lazy cross-tool name reference. If the target module exports the requested
  # function, use the live value; otherwise fall back to a literal default.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
