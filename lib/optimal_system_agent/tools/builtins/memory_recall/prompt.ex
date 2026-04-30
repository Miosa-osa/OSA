defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall.Prompt do
  @moduledoc """
  Dynamic prompt for `memory_recall`.

  Cross-references `memory_save` by its live `Constants.tool_name/0`
  so a rename propagates automatically.
  """

  @doc """
  Render the memory_recall tool prompt.

  `opts` is currently unused but reserved for future customization
  (e.g., omit category hints for minimal-mode sessions).
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    save_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.MemorySave.Constants,
        :tool_name,
        "memory_save"
      )

    """
    Search long-term memory for saved facts, decisions, preferences, and lessons.

    Returns relevant memories ranked by relevance (vector similarity + recency).

    ## WHEN TO RECALL:
    - At session start — search for user preferences and project context
    - Before making decisions — check for relevant past choices
    - When user references something you might have saved before
    - Before answering questions about past work or preferences

    ## Search tips:
    - Use natural language or keywords
    - Filter by category (decision, preference, pattern, lesson, context, project)
    - Limit results with the `limit` parameter (default 10)

    Memories are saved with `#{save_name}` and persist across sessions.
    """
  end

  # Lazy cross-tool name reference. If the target tool's Constants module
  # exists and exports the requested function, use the live value;
  # otherwise fall back to a literal default. Mirrors the lazy-require
  # pattern at `src/tools/ToolSearchTool/prompt.ts:9-19`.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
