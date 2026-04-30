defmodule OptimalSystemAgent.Tools.Builtins.VaultRemember do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "vault_remember"

  @impl true
  def description,
    do: "Store a memory in the vault with automatic fact extraction and categorization"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "content" => %{"type" => "string", "description" => "The memory content to store"},
        "category" => %{
          "type" => "string",
          "description" =>
            "Memory category: fact, decision, lesson, preference, commitment, relationship, project, observation",
          "enum" => [
            "fact",
            "decision",
            "lesson",
            "preference",
            "commitment",
            "relationship",
            "project",
            "observation"
          ]
        },
        "title" => %{"type" => "string", "description" => "Optional title for the memory"}
      },
      "required" => ["content"]
    }
  end

  @impl true
  def execute(%{"content" => content} = args) do
    category = Map.get(args, "category", "fact")
    title = Map.get(args, "title")
    opts = if title, do: %{title: title}, else: %{}

    case OptimalSystemAgent.Vault.remember(content, category, opts) do
      {:ok, path} ->
        facts = OptimalSystemAgent.Vault.FactExtractor.extract(content)
        fact_count = length(facts)

        {:ok,
         "Stored in vault [#{category}] at #{Path.basename(path)}. Extracted #{fact_count} fact(s)."}

      {:error, reason} ->
        {:error, "Failed to store: #{inspect(reason)}"}
    end
  end
end
