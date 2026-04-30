defmodule OptimalSystemAgent.Tools.Builtins.Brief.Prompt do
  @moduledoc """
  Dynamic prompt for the `brief` tool.

  Mirrors `BriefTool/prompt.ts` from the Claude Code reference.
  Cross-references `memory_recall` since it draws from the same store.
  """

  alias OptimalSystemAgent.Tools.Builtins.Brief.Constants

  def render(_opts \\ []) do
    """
    Generate a concise 1-paragraph summary of recent agent activity.

    Reads from the memory store (same source as `memory_recall`) and
    aggregates task completions, decisions, errors, and tool calls from the
    requested time window into a human-readable brief.

    Use this when:
    - The user asks "what did you do?" or "catch me up"
    - You want to surface a summary of background work that completed
    - You need to annotate a handoff with context

    The brief is always one paragraph — dense but scannable. It covers what
    ran, what changed, any errors encountered, and any decisions made. It
    does NOT include verbose tool output or raw log lines.

    Set `window_hours` to scope the summary. Defaults to #{Constants.default_window_hours()} hours.
    Valid values: #{Enum.join(Constants.valid_windows(), ", ")} hours.

    If `topic` is provided, the brief is filtered to entries that match
    that keyword (uses the same keyword index as `memory_recall`).
    """
  end
end
