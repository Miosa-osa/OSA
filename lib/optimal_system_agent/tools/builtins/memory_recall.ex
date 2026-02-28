defmodule OptimalSystemAgent.Tools.Builtins.MemoryRecall do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @impl true
  def name, do: "memory_recall"

  @impl true
  def description,
    do:
      "Search and retrieve information from long-term memory. Use this when the user asks what you remember, or needs to recall past context, preferences, decisions, or facts."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "What to search for in memory (keywords, topic, or question)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}) do
    alias OptimalSystemAgent.Agent.Memory

    # Use relevance-based retrieval (keyword + recency + importance scoring)
    relevant = Memory.recall_relevant(query, 4000)

    if relevant == "" do
      {:ok, "No relevant memories found for: #{query}"}
    else
      {:ok, relevant}
    end
  end
end
