defmodule OptimalSystemAgent.Tools.Builtins.WebFetch.Prompt do
  @moduledoc """
  Dynamic prompt for `web_fetch`.

  Mirrors the description from the the upstream agent CLI WebFetchTool/prompt.ts reference.
  The prompt body is a function (not a static string) so it can reference the
  current `web_search` tool name via `safe_ref/3` — if web_search is renamed,
  the cross-reference updates automatically.
  """

  @doc """
  Render the web_fetch tool prompt.

  `opts` is currently unused but reserved for future signal-aware
  customization (e.g., omit certain sections for constrained contexts).
  """
  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    web_search_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.WebSearch.Constants,
        :tool_name,
        "web_search"
      )

    """
    Fetches a URL and returns readable text: cleaned text for HTML pages, \
    pretty-printed JSON for API responses, raw content otherwise.

    - HTTPS required; HTTP only for localhost. Private/internal IPs are blocked.
    - A success starts with the FINAL url and an `HTTP <status> <content-type>` line, then `---`, then the content.
    - An error status, empty body, or bot-protection page comes back as an ERROR, never as content — fetch a different source rather than guessing at what the page said.
    - For GitHub URLs prefer the `gh` CLI via shell_execute. Use `#{web_search_name}` to discover URLs.
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
