defmodule OptimalSystemAgent.Tools.Builtins.ToolSearch do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def name, do: "tool_search"

  @impl true
  def description, do: "Search for available tools by keyword. Use when you need a tool not in your current list."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Keywords to search for (e.g. 'file edit', 'web search', 'memory')"},
        "max_results" => %{"type" => "integer", "description" => "Maximum results to return (default: 5)"}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = params) do
    max = Map.get(params, "max_results", 5)
    max = if is_integer(max), do: max, else: 5

    results = OptimalSystemAgent.Tools.Registry.search(query, limit: max)

    if results == [] do
      {:ok, "No tools found matching '#{query}'. Try broader keywords."}
    else
      formatted =
        results
        |> Enum.map(fn tool ->
          params_desc =
            case tool.parameters do
              %{"properties" => props} when map_size(props) > 0 ->
                props
                |> Enum.map(fn {k, v} -> "  #{k}: #{v["type"] || "any"} — #{v["description"] || ""}" end)
                |> Enum.join("\n")

              _ ->
                "  (no parameters)"
            end

          required =
            case tool.parameters do
              %{"required" => req} when is_list(req) -> "Required: #{Enum.join(req, ", ")}"
              _ -> ""
            end

          """
          ## #{tool.name}
          #{tool.description}

          Parameters:
          #{params_desc}
          #{required}
          """
        end)
        |> Enum.join("\n---\n")

      {:ok, "Found #{length(results)} tool(s):\n\n#{formatted}"}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: query"}
end
