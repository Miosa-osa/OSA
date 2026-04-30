defmodule OptimalSystemAgent.Tools.Builtins.WebSearch.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `web_search`.

  Behaviour split:
    * `validate/2`           — type checks input shape (cheap, no I/O)
    * `check_permissions/2`  — always allow (no local resource access)
    * `execute/2`            — DuckDuckGo HTML search + result parsing

  All logic moved verbatim from the original `web_search.ex`. No semantic
  changes — just relocation into the validate / check_permissions / execute
  split required by the structured layout.

  Implementation notes:
    - Uses the DuckDuckGo HTML endpoint (no API key required).
    - HTML input is capped at 300KB before regex scanning to prevent catastrophic
      backtracking on pathological pages.
    - Falls back to link-only parsing if block-level parsing yields no results.
    - DDG redirect URLs (//duckduckgo.com/l/?uddg=...) are decoded to real URLs.
  """

  alias OptimalSystemAgent.Tools.Builtins.WebSearch.Constants
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"query" => query} = input, _ctx) when is_binary(query),
    do: {:ok, input}

  def validate(%{"query" => _}, _ctx),
    do: {:error, "query must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: query", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) :: {:allow, map()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"query" => query} = input, _ctx) do
    limit = input["limit"] || Constants.default_limit()
    trimmed = String.trim(query)

    if trimmed == "" do
      {:error, "query must not be empty"}
    else
      search(trimmed, limit)
    end
  end

  # ── Private: DuckDuckGo search ────────────────────────────────────────

  defp search(query, limit) do
    encoded = URI.encode_query(%{"q" => query})
    url = Constants.ddg_url() <> "?" <> encoded

    response =
      Req.get(url,
        receive_timeout: 20_000,
        max_redirects: 3,
        headers: [
          {"user-agent", "Mozilla/5.0 (compatible; OSAAgent/1.0)"},
          {"accept", "text/html,application/xhtml+xml"}
        ]
      )

    case response do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        results = parse_ddg_results(body, limit)

        if results == [] do
          {:error,
           "No results found for \"#{query}\". " <>
             "If this persists, consider configuring a search API key in ~/.osa/config.yaml."}
        else
          formatted = format_results(results)
          {:ok, "Search results for: #{query}\n\n#{formatted}"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error,
         "DuckDuckGo returned HTTP #{status}. " <>
           "Consider configuring a search API key for reliable results."}

      {:error, reason} ->
        {:error,
         "Search failed: #{inspect(reason)}. " <>
           "Consider configuring a search API key in ~/.osa/config.yaml."}
    end
  end

  # ── Private: HTML parsing ─────────────────────────────────────────────

  # Parse DuckDuckGo HTML search results.
  # DDG HTML layout: result links use class="result__a", snippets use class="result__snippet".
  defp parse_ddg_results(html, limit) when is_binary(html) do
    # Cap input to 300KB to prevent catastrophic backtracking on the nested-div regex.
    html = String.slice(html, 0, 300_000)

    # Extract result blocks — each result is wrapped in a div with class "result"
    # We pair result__a (title+URL) with result__snippet from the same block
    result_blocks =
      Regex.scan(
        ~r/<div[^>]+class="[^"]*result[^"]*"[^>]*>(.*?)<\/div>\s*<\/div>/is,
        html,
        capture: :all_but_first
      )

    if result_blocks == [] do
      # Fallback: extract all result__a links without block parsing
      parse_links_only(html, limit)
    else
      result_blocks
      |> Enum.take(limit * 2)
      |> Enum.flat_map(fn [block] -> parse_result_block(block) end)
      |> Enum.take(limit)
    end
  end

  defp parse_ddg_results(_html, _limit), do: []

  defp parse_result_block(block) do
    with [_ | [title_raw]] <-
           Regex.run(~r/<a[^>]+class="[^"]*result__a[^"]*"[^>]*>(.*?)<\/a>/is, block),
         [_ | [url_raw]] <-
           Regex.run(
             ~r/<a[^>]+class="[^"]*result__a[^"]*"[^>]*\shref="([^"]+)"/is,
             block
           ) do
      title = strip_tags(title_raw)
      url = resolve_ddg_url(url_raw)

      snippet =
        case Regex.run(
               ~r/<a[^>]+class="[^"]*result__snippet[^"]*"[^>]*>(.*?)<\/a>/is,
               block,
               capture: :all_but_first
             ) do
          [[raw]] -> strip_tags(raw)
          _ -> ""
        end

      if title != "" and url != "" do
        [{title, url, snippet}]
      else
        []
      end
    else
      _ -> []
    end
  end

  defp parse_links_only(html, limit) do
    Regex.scan(
      ~r/<a[^>]+class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/is,
      html,
      capture: :all_but_first
    )
    |> Enum.take(limit)
    |> Enum.map(fn [url_raw, title_raw] ->
      {strip_tags(title_raw), resolve_ddg_url(url_raw), ""}
    end)
    |> Enum.filter(fn {title, url, _} -> title != "" and url != "" end)
  end

  # DDG sometimes uses redirect URLs like //duckduckgo.com/l/?uddg=https%3A%2F%2F...
  defp resolve_ddg_url("//" <> rest) do
    uri = "https://" <> rest

    case Regex.run(~r/[?&]uddg=([^&]+)/, uri) do
      [_, encoded] ->
        case URI.decode(encoded) do
          decoded when is_binary(decoded) -> decoded
          _ -> uri
        end

      _ ->
        uri
    end
  end

  defp resolve_ddg_url("http" <> _ = url), do: url
  defp resolve_ddg_url(url), do: url

  defp strip_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp format_results(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {{title, url, snippet}, idx} ->
      base = "#{idx}. [#{title}](#{url})"
      if snippet != "", do: base <> "\n   #{snippet}", else: base
    end)
  end
end
