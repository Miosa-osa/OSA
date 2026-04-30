defmodule OptimalSystemAgent.Tools.Builtins.WebSearch.Prompt do
  @moduledoc """
  Dynamic prompt for `web_search`.

  Mirrors the dynamic prompt pattern from WebSearchTool/prompt.ts — includes
  the current date in the prompt so the model uses the correct year in queries.
  References `web_fetch` tool name via `safe_ref/3` so a rename propagates
  automatically.
  """

  @doc """
  Render the web_search tool prompt.

  `opts` accepts:
    * `:current_date` — override the injected date string (useful in tests)
  """
  @spec render(keyword()) :: String.t()
  def render(opts \\ []) do
    web_fetch_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.WebFetch.Constants,
        :tool_name,
        "web_fetch"
      )

    current_date = opts[:current_date] || current_month_year()

    """
    Searches the web using DuckDuckGo and returns the top results with titles, URLs, and snippets.

    Usage notes:
      - Use this tool when you need up-to-date information beyond your knowledge cutoff.
      - Returns up to `limit` results (default #{OptimalSystemAgent.Tools.Builtins.WebSearch.Constants.default_limit()}).
      - After searching, use `#{web_fetch_name}` to retrieve the full content of promising URLs.
      - Include sources (URLs) in your response when using web search results.
      - Web search is best-effort; if DuckDuckGo returns no results, consider rephrasing the query.
      - Results may be sparse for very niche or very recent topics.

    IMPORTANT — Use the correct year in search queries:
      - The current date is #{current_date}. Use this year when searching for recent information,
        documentation, or current events. Do NOT use last year's date in queries.

    After answering, include a "Sources:" section listing all relevant URLs from search results:

        Sources:
        - [Title](https://example.com/page)
    """
  end

  defp current_month_year do
    now = Date.utc_today()
    month = now.month |> month_name()
    "#{month} #{now.year}"
  end

  defp month_name(1), do: "January"
  defp month_name(2), do: "February"
  defp month_name(3), do: "March"
  defp month_name(4), do: "April"
  defp month_name(5), do: "May"
  defp month_name(6), do: "June"
  defp month_name(7), do: "July"
  defp month_name(8), do: "August"
  defp month_name(9), do: "September"
  defp month_name(10), do: "October"
  defp month_name(11), do: "November"
  defp month_name(12), do: "December"

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
