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
  def execute(%{"query" => _query}) do
    # OptimalSystemAgent.Vault backend is not present in this build.
    {:error, "Vault backend not present in this build"}
  end
end
