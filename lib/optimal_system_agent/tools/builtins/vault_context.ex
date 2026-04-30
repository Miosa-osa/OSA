defmodule OptimalSystemAgent.Tools.Builtins.VaultContext do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "vault_context"

  @impl true
  def description, do: "Build profiled context from vault memories for a task or query"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "profile" => %{
          "type" => "string",
          "description" => "Context profile: default, planning, incident, handoff",
          "enum" => ["default", "planning", "incident", "handoff"]
        },
        "query" => %{
          "type" => "string",
          "description" => "Optional query to filter relevant memories"
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(args) do
    profile = args |> Map.get("profile", "default") |> String.to_existing_atom()
    query = Map.get(args, "query")
    opts = if query, do: [query: query], else: []

    context = OptimalSystemAgent.Vault.context(profile, opts)

    if context == "" do
      {:ok, "No vault memories found for this context."}
    else
      {:ok, context}
    end
  end
end
