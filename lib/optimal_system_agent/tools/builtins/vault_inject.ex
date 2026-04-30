defmodule OptimalSystemAgent.Tools.Builtins.VaultInject do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "vault_inject"

  @impl true
  def description,
    do: "Query vault for memories matching keywords — returns context for prompt injection"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Keywords or query to match against vault"
        },
        "max_items" => %{
          "type" => "integer",
          "description" => "Maximum items to return (default: 10)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = args) do
    max_items = Map.get(args, "max_items", 10)
    result = OptimalSystemAgent.Vault.Inject.query(query, max_items: max_items)

    if result == "" do
      {:ok, "No matching vault memories found."}
    else
      {:ok, result}
    end
  end
end
