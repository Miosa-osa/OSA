defmodule OptimalSystemAgent.Tools.Builtins.VaultCheckpoint do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "vault_checkpoint"

  @impl true
  def description,
    do: "Create a mid-session vault checkpoint — flushes observations and refreshes dirty flag"

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Session identifier"}
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def execute(%{"session_id" => session_id}) do
    OptimalSystemAgent.Vault.checkpoint(session_id)
    {:ok, "Vault checkpoint saved for session #{session_id}."}
  end
end
