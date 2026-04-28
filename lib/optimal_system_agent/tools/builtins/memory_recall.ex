defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def safety, do: :read_safe

  @impl true
  def name, do: "memory_recall"

  @impl true
  def description,
    do:
      "Search long-term memory for saved facts, decisions, preferences, and lessons. Returns relevant memories ranked by relevance."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query — keywords or natural language"
        },
        "category" => %{
          "type" => "string",
          "description" => "Filter by category",
          "enum" => ["decision", "preference", "pattern", "lesson", "context", "project"]
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results (default 10)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = args) do
    opts =
      [limit: args["limit"] || 10]
      |> maybe_add(:category, args["category"])

    case OptimalSystemAgent.Memory.recall(query, opts) do
      {:ok, []} ->
        {:ok, "No memories found for: #{query}"}

      {:ok, entries} ->
        formatted =
          entries
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, idx} ->
            rel =
              if is_float(entry.relevance),
                do: Float.round(entry.relevance, 2),
                else: entry.relevance

            "#{idx}. [#{entry.category}] #{entry.content} (#{entry.scope}, relevance: #{rel})"
          end)
          |> Enum.join("\n")

        {:ok, "Found #{length(entries)} memories\n---\n#{formatted}"}

      {:error, reason} ->
        {:error, "Memory recall failed: #{inspect(reason)}"}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, val), do: [{key, val} | opts]
end
