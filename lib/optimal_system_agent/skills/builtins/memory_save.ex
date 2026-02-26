defmodule OptimalSystemAgent.Skills.Builtins.MemorySave do
  @behaviour OptimalSystemAgent.Skills.Behaviour

  @impl true
  def name, do: "memory_save"

  @impl true
  def description, do: "Save important information to long-term memory"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "content" => %{"type" => "string", "description" => "Information to remember"},
        "category" => %{"type" => "string", "description" => "Category (e.g., 'preference', 'fact', 'decision')"}
      },
      "required" => ["content"]
    }
  end

  @impl true
  def execute(%{"content" => content} = args) do
    category = Map.get(args, "category", "general")
    OptimalSystemAgent.Agent.Memory.remember(content, category)
    {:ok, "Saved to long-term memory under [#{category}]."}
  end
end
