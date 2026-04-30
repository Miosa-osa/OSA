defmodule OptimalSystemAgent.Tools.Builtins.VaultWake do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "vault_wake"

  @impl true
  def description, do: "Start a vault session — detects dirty deaths and recovers previous state"

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
    case OptimalSystemAgent.Vault.wake(session_id) do
      {:ok, :clean} ->
        {:ok, "Vault session started cleanly."}

      {:ok, :recovered} ->
        {:ok, "Vault session started with recovery from previous dirty death."}
    end
  end
end
