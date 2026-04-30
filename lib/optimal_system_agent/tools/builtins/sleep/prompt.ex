defmodule OptimalSystemAgent.Tools.Builtins.Sleep.Prompt do
  @moduledoc """
  Dynamic prompt for the `sleep` tool.

  Mirrors `src/tools/SleepTool/prompt.ts` from the Claude Code reference.
  """

  alias OptimalSystemAgent.Tools.Builtins.Sleep.Constants

  def render(_opts \\ []) do
    """
    Wait for a specified duration. The user can interrupt the sleep at any time.

    Use this when the user tells you to sleep or rest, when you have nothing to do,
    or when you're waiting for something to change before re-checking.

    You may receive `<tick>` prompts — these are periodic check-ins. Look for
    useful work to do before sleeping again.

    You can call this concurrently with other tools — it won't interfere with them.

    Prefer this over `shell_execute(sleep ...)` — it doesn't hold a shell process,
    survives across LLM turns, and integrates with the agent's interrupt signals.

    Each wake-up costs an API call, but the prompt cache expires after roughly 5
    minutes of inactivity — balance the duration accordingly. Maximum #{Constants.max_seconds()} seconds.
    """
  end
end
