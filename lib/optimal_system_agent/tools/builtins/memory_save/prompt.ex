defmodule OptimalSystemAgent.Tools.Builtins.MemorySave.Prompt do
  @moduledoc """
  Dynamic prompt for `memory_save`.

  Cross-references `memory_recall` by its live `Constants.tool_name/0`
  so a rename propagates automatically.
  """

  @doc """
  Render the memory_save tool prompt.

  `opts` is currently unused but reserved for future customization
  (e.g., omit category hints for minimal-mode sessions).
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    recall_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.MemoryRecall.Constants,
        :tool_name,
        "memory_recall"
      )

    """
    Save context to persistent memory that survives the session: user
    preferences, corrections, decisions, architectural choices, patterns that
    worked or failed, names, project facts. When the user says "remember",
    "note", or "save", call this RIGHT THEN.

    Iron Rule: never make a mental note — saying "I'll remember that" without
    calling this tool loses it. Save as you go; don't batch, don't ask
    permission. Save only what you VERIFIED this turn, never your own
    model/version/context window, and never "current" anything that can change
    without you. Note uncertainty inline ("as of X, per Y"), and flag it when
    you rely on memory for a fact you did not verify this turn. Retrieve with
    `#{recall_name}`.
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
