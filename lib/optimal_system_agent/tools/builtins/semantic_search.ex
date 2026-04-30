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
    alias OptimalSystemAgent.Agent.Memory

    # recall_relevant uses keyword matching (+ optional semantic sidecar)
    # and returns a formatted string already budgeted to 2000 tokens
    result = Memory.recall_relevant(query, 2000)

    if result == "" do
      nil
    else
      result
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Learning Search ───────────────────────────────────────────────

  defp search_learning(query) do
    alias OptimalSystemAgent.Agent.Learning

    keywords = extract_keywords(query)

    patterns = Learning.patterns()
    solutions = Learning.solutions()

    matching_patterns =
      patterns
      |> Enum.filter(fn {key, _val} -> matches_any?(to_string(key), keywords) end)
      |> Enum.take(5)

    matching_solutions =
      solutions
      |> Enum.filter(fn {key, _val} -> matches_any?(to_string(key), keywords) end)
      |> Enum.take(5)

    if matching_patterns == [] and matching_solutions == [] do
      nil
    else
      format_learning_results(matching_patterns, matching_solutions)
    end
  rescue
    e -> {:error, Exception.message(e)}
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
          Enum.map_join(patterns, "\n", fn {key, count} ->
            "- #{key}: observed #{count}x"
          end)

        ["### Learned Patterns\n#{lines}" | parts]
      else
        parts
      end

    parts =
      if solutions != [] do
        lines =
          Enum.map_join(solutions, "\n", fn {error_type, fix} ->
            "- **#{error_type}**: #{fix}"
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
