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
    Save important context to persistent long-term memory. Memories persist across sessions.

    ## WHEN TO SAVE (immediately, never delay):
    - User preferences, corrections, decisions
    - Architectural choices, patterns that worked or failed
    - Names, project context, technical facts
    - When user says "remember", "note", or "save" — call it RIGHT THEN

    ## The Iron Rule
    Never make mental notes. If it matters, call memory_save.
    Mental notes die when the session ends. Saying "I'll remember that"
    without calling a tool is LYING — the information is GONE.

    Save as you go. Don't batch. Don't wait for end-of-task. Don't ask permission.

    ## Save what you VERIFIED, never what you inferred
    Reading one config file is not verification — another file or env can
    override it. If a fact is knowable from runtime state, read runtime state
    instead of persisting a guess (your own model/version/context window are
    already in Runtime Context — never save them as a discovery). Don't save
    "current" anything that can change without you. If it's uncertain, say so
    in the content ("as of X, per Y") rather than asserting it.

    Relying on memory for a fact you didn't verify this turn? Say so. Never
    present unverified memory-derived facts as confirmed-current.

    Use `#{recall_name}` to retrieve saved memories.
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
