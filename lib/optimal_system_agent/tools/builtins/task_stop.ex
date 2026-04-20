defmodule OptimalSystemAgent.Tools.Builtins.TaskStop do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.Loop

  @impl true
  def name, do: "task_stop"

  @impl true
  def deferred?, do: true

  @impl true
  def description do
    "Stop a running agent task by session ID.\n\n" <>
    "Use when a background agent is taking too long, is stuck, or is no longer needed."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["agent_id"],
      "properties" => %{
        "agent_id" => %{
          "type" => "string",
          "description" => "Session ID of the agent to stop"
        }
      }
    }
  end

  @impl true
  def execute(%{"agent_id" => agent_id}) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
      [{_pid, _}] ->
        Loop.cancel(agent_id)
        {:ok, "Agent #{agent_id} cancelled."}

      [] ->
        {:ok, "Agent #{agent_id} not found or already completed."}
    end
  rescue
    e -> {:error, "Failed to stop agent: #{Exception.message(e)}"}
  end

  def execute(_), do: {:error, "Missing required parameter: agent_id"}
end
