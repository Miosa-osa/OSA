defmodule OptimalSystemAgent.Tools.Builtins.SemanticSearch do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "semantic_search"

  @impl true
  def description,
    do:
      "Search across long-term memory and learned patterns using keyword-based semantic matching. Use this to surface relevant past context, decisions, solutions, and patterns before solving a problem."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The search query — keywords, topic, or question to look up"
        },
        "scope" => %{
          "type" => "string",
          "enum" => ["memory", "learning", "all"],
          "description" =>
            "Which store to search: \"memory\" (MEMORY.md entries), \"learning\" (patterns and solutions), or \"all\" (both). Defaults to \"all\"."
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = args) do
    scope = Map.get(args, "scope", "all")

    memory_results = if scope in ["memory", "all"], do: search_memory(query), else: nil
    learning_results = if scope in ["learning", "all"], do: search_learning(query), else: nil

    output = build_output(query, memory_results, learning_results)

    {:ok, output}
  end

  # ── Memory Search ─────────────────────────────────────────────────

  defp search_memory(query) do
    # `OptimalSystemAgent.Agent.Memory` does not exist and never has, so this
    # branch used to raise `UndefinedFunctionError` on every call and get
    # swallowed by the `rescue` below into a "Memory search error" section.
    # The real facade is `SDK.Memory.recall_relevant/2` (the same one
    # `data_routes.ex:93` uses); it returns a LIST of entry maps, not a
    # pre-formatted string, so format it here.
    alias OptimalSystemAgent.SDK.Memory

    case Memory.recall_relevant(query, 2000) do
      [] ->
        nil

      entries when is_list(entries) ->
        Enum.map_join(entries, "\n", fn entry ->
          content = entry[:content] || entry["content"] || inspect(entry)
          "- #{String.slice(to_string(content), 0, 300)}"
        end)

      _ ->
        nil
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Learning Search ───────────────────────────────────────────────

  defp search_learning(query) do
    # Same rename drift as `search_memory/1`: the module is
    # `OptimalSystemAgent.Memory.Learning`, not `Agent.Learning`.
    alias OptimalSystemAgent.Memory.Learning

    keywords = extract_keywords(query)

    # `patterns/0` and `solutions/0` return `{:ok, [map()]}` — a list of pattern
    # maps (`:description`, `:trigger`, `:response`, `:occurrences`, ...), not
    # the `key => count` map this tool used to assume.
    {:ok, patterns} = Learning.patterns()
    {:ok, solutions} = Learning.solutions()

    matching_patterns =
      patterns
      |> Enum.filter(&pattern_matches?(&1, keywords))
      |> Enum.take(5)

    matching_solutions =
      solutions
      |> Enum.filter(&pattern_matches?(&1, keywords))
      |> Enum.take(5)

    if matching_patterns == [] and matching_solutions == [] do
      nil
    else
      format_learning_results(matching_patterns, matching_solutions)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp pattern_matches?(pattern, keywords) do
    haystack =
      [pattern[:description], pattern[:trigger], pattern[:response], pattern[:category]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    matches_any?(haystack, keywords)
  end

  defp matches_any?(text, keywords) do
    text_lower = String.downcase(text)
    Enum.any?(keywords, fn kw -> String.contains?(text_lower, kw) end)
  end

  defp extract_keywords(query) do
    query
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(fn w -> String.length(w) > 2 end)
    |> Enum.uniq()
  end

  defp format_learning_results(patterns, solutions) do
    parts = []

    parts =
      if patterns != [] do
        lines =
          Enum.map_join(patterns, "\n", fn p ->
            "- #{p[:description] || p[:trigger] || p[:id]}: observed #{p[:occurrences] || 1}x"
          end)

        ["### Learned Patterns\n#{lines}" | parts]
      else
        parts
      end

    parts =
      if solutions != [] do
        lines =
          Enum.map_join(solutions, "\n", fn s ->
            "- **#{s[:trigger] || s[:description] || s[:id]}**: #{s[:response]}"
          end)

        ["### Known Solutions\n#{lines}" | parts]
      else
        parts
      end

    parts |> Enum.reverse() |> Enum.join("\n\n")
  end

  # ── Output Assembly ───────────────────────────────────────────────

  defp build_output(query, memory_results, learning_results) do
    sections = []

    sections =
      case memory_results do
        nil -> sections
        {:error, reason} -> ["**Memory search error:** #{reason}" | sections]
        text -> ["## Memory\n\n#{text}" | sections]
      end

    sections =
      case learning_results do
        nil -> sections
        {:error, reason} -> ["**Learning search error:** #{reason}" | sections]
        text -> ["## Learned Patterns & Solutions\n\n#{text}" | sections]
      end

    if sections == [] do
      "No results found for: #{query}"
    else
      sections |> Enum.reverse() |> Enum.join("\n\n---\n\n")
    end
  end
end
