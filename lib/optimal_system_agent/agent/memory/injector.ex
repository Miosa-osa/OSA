defmodule OptimalSystemAgent.Agent.Memory.Injector do
  @moduledoc """
  Relevant-memory injector — the REAL implementation.

  Filters and orders a set of memory entries for inclusion in a prompt, and
  renders them into a compact system block.

  History / landmine fixed: this module previously did
  `defdelegate inject_relevant/2, format_for_prompt/1 to: MiosaMemory.Injector`,
  while the `MiosaMemory.Injector` shim delegated straight back here (its
  `Code.ensure_loaded?/1` guard is always true because this module compiles).
  That produced an A->B->A->B infinite mutual-delegation loop (stack overflow)
  the instant anything called it. Delegation now flows in exactly ONE direction:
  MiosaMemory.Injector -> this module. This module never delegates back.
  """

  @type entry :: map()
  @type injection_context :: map()

  # Default cap on how many entries to inject when the context doesn't specify.
  @default_limit 10

  @doc """
  Select the entries relevant to `context`, most-relevant first.

  `context` may carry:
    - `:keywords` — a list of query keywords, OR
    - `:query`    — a raw query string (tokenised into keywords), and
    - `:limit`    — max entries to return (default #{@default_limit}).

  When no keywords are derivable the entries are returned ranked but unfiltered.
  Ranking favours signal weight, then relevance.
  """
  @spec inject_relevant([entry()], injection_context()) :: [entry()]
  def inject_relevant(entries, context) when is_list(entries) and is_map(context) do
    keywords = context_keywords(context)
    limit = context_limit(context)

    entries
    |> Enum.filter(&relevant?(&1, keywords))
    |> Enum.sort_by(&entry_rank/1, :desc)
    |> Enum.take(limit)
  end

  def inject_relevant(entries, _context) when is_list(entries), do: entries
  def inject_relevant(_entries, _context), do: []

  @doc """
  Render selected entries into a `[System: Relevant memory]` markdown block.
  Returns an empty string when there is nothing to inject.
  """
  @spec format_for_prompt([entry()]) :: String.t()
  def format_for_prompt([]), do: ""

  def format_for_prompt(entries) when is_list(entries) do
    body = Enum.map_join(entries, "\n", fn e -> "- " <> entry_content(e) end)
    "[System: Relevant memory]\n" <> body
  end

  def format_for_prompt(_), do: ""

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp context_keywords(context) do
    cond do
      is_list(Map.get(context, :keywords)) -> normalize_keywords(Map.get(context, :keywords))
      is_binary(Map.get(context, :query)) -> tokenize(Map.get(context, :query))
      true -> []
    end
  end

  defp context_limit(context) do
    case Map.get(context, :limit) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_limit
    end
  end

  defp normalize_keywords(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp tokenize(query) do
    query
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  # No keywords → don't filter anything out.
  defp relevant?(_entry, []), do: true

  defp relevant?(entry, keywords) do
    haystack = String.downcase(entry_keywords(entry) <> " " <> entry_content(entry))
    Enum.any?(keywords, &String.contains?(haystack, &1))
  end

  defp entry_rank(entry) do
    signal = to_float(get_field(entry, :signal_weight), 0.5)
    relevance = to_float(get_field(entry, :relevance), 0.5)
    signal * 0.6 + relevance * 0.4
  end

  defp entry_content(entry), do: entry |> get_field(:content) |> to_string()
  defp entry_keywords(entry), do: entry |> get_field(:keywords) |> to_string()

  defp get_field(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, to_string(key))
  end

  defp get_field(_entry, _key), do: nil

  defp to_float(v, _default) when is_float(v), do: v
  defp to_float(v, _default) when is_integer(v), do: v * 1.0
  defp to_float(_v, default), do: default
end
