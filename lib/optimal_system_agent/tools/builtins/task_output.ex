defmodule OptimalSystemAgent.Tools.Builtins.TaskOutput do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.Loop

  @impl true
  def name, do: "task_output"

  @impl true
  def deferred?, do: true

  @impl true
  def description do
    "Get the output/status of a running or completed agent task.\n\n" <>
    "Use to check on background agents or retrieve their results."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["agent_id"],
      "properties" => %{
        "agent_id" => %{
          "type" => "string",
          "description" => "Session ID of the agent to check"
        }
      }
    }
  end

  @impl true
  def execute(%{"agent_id" => agent_id}) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) do
      [{_pid, _}] ->
        # Agent is still running — get its state
        case Loop.get_state(agent_id) do
          {:ok, state} ->
            iter = state[:iteration_count] || state[:iteration] || 0
            tokens = state[:estimated_tokens] || 0
            status = state[:status] || :unknown

            {:ok, "Agent #{agent_id} is #{status}.\n" <>
              "- Iterations: #{iter}\n" <>
              "- Tokens used: #{tokens}\n" <>
              "- Status: running"}

          _ ->
            {:ok, "Agent #{agent_id} is running (state unavailable)."}
        end

      [] ->
        # Agent is not running — check if we have a stored result
        {:ok, "Agent #{agent_id} is not running. It may have completed or was never started."}
    end
  rescue
    e -> {:error, "Failed to get task output: #{Exception.message(e)}"}
  end

  def execute(_), do: {:error, "Missing required parameter: agent_id"}
end
