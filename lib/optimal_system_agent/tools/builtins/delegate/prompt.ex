defmodule OptimalSystemAgent.Tools.Builtins.Delegate.Prompt do
  @moduledoc """
  Dynamic prompt for the `delegate` tool.

  The description is a function (not a static string) so it can reference
  other tool names via `safe_ref/3` — when `ask_user` is renamed this prompt
  updates automatically, mirroring the lazy-require pattern at
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

    file_read_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.FileRead.Constants,
        :tool_name,
        "file_read"
      )

    roles_list = Constants.roles() |> Enum.join(", ")

    """
    Launch a specialized agent to handle a subtask autonomously.

    Each agent gets its own context window, model selection, and tool access.

    ## When to Use
    - Task has multiple independent parts that can run in parallel
    - A specialized role (explore, code-review, tester) would do better work
    - You need codebase context fast and cheap: dispatch role='explore' first
    - You need an implementation plan: dispatch role='plan'
    - Open-ended multi-step work: dispatch role='general-purpose'
    - Long-running research: it already runs in the background, so keep working
    - Agent needs your conversation context: use fork=true

    ## When NOT to Use
    - Simple single-file tasks (just do it yourself)
    - Tasks needing user interaction (use #{ask_user_name} instead)
    - Quick file reads (use #{file_read_name} directly)

    ## Foreground vs Background
    - Background (DEFAULT): returns immediately with an agentId + output_file; a
      <task-notification> is injected here when it finishes, whether you are still
      working or have gone idle. While it runs: do NOT poll with task_output, do
      NOT read its output file, and do NOT redo its work yourself.
    - background=false: you BLOCK until the agent returns, and so does the user —
      no message they type can reach you until it finishes. Only ask for this when
      the result gates your VERY NEXT step and the agent is genuinely quick.
    - Parallel work: prefer ONE call with tasks:[...] (a single wave with grouped
      display) over sequential delegate calls.
    - Continue a finished agent with task_resume or message_agent (send to its
      agentId) — it resumes with its full prior transcript.

    ## Writing the Prompt
    Brief the agent like a colleague who just walked in — they haven't seen this conversation.
    - Explain what you're trying to accomplish and why
    - Include all file paths, requirements, and constraints
    - State the expected output structure and stop condition
    - Ask for commands run, files touched, evidence, and remaining risks when relevant
    - If you need a short response, say so
    - Terse command-style prompts produce shallow, generic work

    ## Handoff Packet
    For build tasks, include:
    - Objective
    - Relevant files/directories
    - Constraints and forbidden actions
    - Required verification
    - Expected result format

    Worktree isolation never merges by default. Use merge_worktree=true only
    when you explicitly want a successful isolated agent to merge its branch.

    ## Roles
    #{roles_list}.
    Omit role for a generic agent.
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
