defmodule OptimalSystemAgent.Skills.Builtins.WebSearch do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web for information using Brave Search API"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search query"}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}) do
    api_key = Application.get_env(:optimal_system_agent, :brave_api_key)

    if api_key do
      case Req.get("https://api.search.brave.com/res/v1/web/search",
             params: [q: query, count: 5],
             headers: [{"X-Subscription-Token", api_key}, {"Accept", "application/json"}]
           ) do
        {:ok, %{status: 200, body: body}} ->
          results = get_in(body, ["web", "results"]) || []
          formatted = Enum.map_join(results, "\n\n", fn r ->
            "**#{r["title"]}**\n#{r["url"]}\n#{r["description"]}"
          end)
          {:ok, formatted}

        {:ok, %{status: status}} ->
          {:error, "Brave Search returned #{status}"}

        {:error, reason} ->
          {:error, "Search failed: #{inspect(reason)}"}
      end
    else
      {:error, "Web search not configured. Set BRAVE_API_KEY to enable."}
    end
  end
end
