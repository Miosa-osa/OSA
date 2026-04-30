defmodule OptimalSystemAgent.Tools.Builtins.WebFetch.Prompt do
  @moduledoc """
  Dynamic prompt for `web_fetch`.

  Mirrors the description from the Claude Code WebFetchTool/prompt.ts reference.
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
    Fetches content from a URL and returns readable text. Returns cleaned text for HTML pages, \
    pretty-printed JSON for API responses, and raw content for other types.

    Usage notes:
      - The URL must be a fully-formed valid URL (scheme + host required).
      - HTTPS URLs are required. HTTP is only allowed for localhost.
      - Requests to private/internal IP addresses (RFC 1918, link-local, loopback) are blocked.
      - DNS rebinding protection: hostnames are resolved and checked before the request is made.
      - Up to #{OptimalSystemAgent.Tools.Builtins.WebFetch.Constants.max_redirects()} redirects are followed; each redirect target is validated.
      - HTML pages have scripts/styles stripped and entities decoded before being returned.
      - Results are truncated at `max_length` characters (default #{OptimalSystemAgent.Tools.Builtins.WebFetch.Constants.default_max_length()}).
      - This tool is read-only and does not modify any files.
      - For GitHub URLs, prefer the `gh` CLI via shell_execute instead.
      - To discover URLs to fetch, use `#{web_search_name}` first.
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
