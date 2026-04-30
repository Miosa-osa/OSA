defmodule OptimalSystemAgent.Tools.Builtins.VaultSleep do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "vault_sleep"

  @impl true
  def description,
    do: "End a vault session cleanly — creates handoff document and clears dirty flag"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Session identifier"},
        "summary" => %{"type" => "string", "description" => "Session summary for the handoff"},
        "next_steps" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of next steps for the handoff"
        }
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def execute(%{"session_id" => session_id} = args) do
    context = %{
      summary: Map.get(args, "summary", "Session ended."),
      next_steps: Map.get(args, "next_steps", []),
      open_questions: Map.get(args, "open_questions", [])
    }

    OptimalSystemAgent.Vault.sleep(session_id, context)
    {:ok, "Vault session ended cleanly. Handoff document created."}
  end
end
