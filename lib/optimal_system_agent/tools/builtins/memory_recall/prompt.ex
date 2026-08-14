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
    Search long-term memory for facts, decisions, preferences, and lessons saved
    with `#{save_name}`, ranked by vector similarity and recency. Recall at
    session start for user preferences and project context, before decisions that
    may have a precedent, and before answering about past work.
    """
  end

  # Lazy cross-tool name reference. If the target tool's Constants module
  # exists and exports the requested function, use the live value;
  # otherwise fall back to a literal default. Mirrors the lazy-require
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
