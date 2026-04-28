defmodule OptimalSystemAgent.Tools.Builtins.SessionSearch do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def safety, do: :read_safe

  @impl true
  def name, do: "session_search"

  @impl true
  def description,
    do: "Search past conversation sessions for messages matching a query."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max results (default 5)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = args) do
    limit = args["limit"] || 10

    # Try FTS5-backed search first, fall back to Memory.search_sessions
    results =
      try do
        OptimalSystemAgent.Store.SessionTranscript.search(query, limit: limit)
      rescue
        _ -> []
      end

    results =
      if results == [] do
        # Fallback to legacy memory search
        case OptimalSystemAgent.Memory.search_sessions(query, limit: limit) do
          {:ok, r} -> r
          _ -> []
        end
      else
        results
      end

    if results == [] do
      {:ok, "No past sessions found matching: #{query}"}
    else
      formatted =
        results
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} ->
          highlight = Map.get(result, :highlight)
          content_preview = highlight || String.slice(Map.get(result, :content, ""), 0, 200)
          session = Map.get(result, :session_id, "unknown")
          role = Map.get(result, :role, "?")
          ts = Map.get(result, :inserted_at, "")
          "#{idx}. [#{session}] #{role} (#{ts})\n   #{content_preview}"
        end)
        |> Enum.join("\n\n")

      {:ok, "Found #{length(results)} match(es):\n\n#{formatted}"}
    end
  end
end
