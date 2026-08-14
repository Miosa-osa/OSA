defmodule OptimalSystemAgent.Tools.Builtins.WebSearch.Prompt do
  @moduledoc """
  Dynamic prompt for `web_search`.

  References `web_fetch` tool name via `safe_ref/3` so a rename propagates
  automatically.

  ## No date is interpolated here, deliberately

  This description used to splice in the current month and year. That put a
  value that changes into the STATIC prompt prefix — the block the provider
  prompt-cache keys on — so the cache was guaranteed to miss on the first
  request of every month, for a fact the model already has: `Agent.Context`
  emits `Today's date: <iso8601>` in the per-session environment block, which
  is outside the cached prefix and correct to the day rather than the month.
  One copy, in the place where a changing value belongs.
  """

  @doc """
  Render the web_search tool prompt.

  `opts` is currently unused; it is retained so callers (and the tool's
  `prompt/1` callback) keep a stable arity.
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    web_fetch_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.WebFetch.Constants,
        :tool_name,
        "web_fetch"
      )

    """
    Searches the web using DuckDuckGo; returns titles, URLs, and snippets for
    information beyond your knowledge cutoff. Use the CURRENT year in
    time-sensitive queries — "Today's date" in your environment block has it.
    Use `#{web_fetch_name}` to read promising URLs in full, and end your answer with
    a "Sources:" section listing the URLs used, as
    `- [Title](https://example.com/page)`.
    """
  end

  # Lazy cross-tool name reference. If the target Constants module exists and
  # exports the requested function, use the live value; otherwise fall back to
  # the literal default.
  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
