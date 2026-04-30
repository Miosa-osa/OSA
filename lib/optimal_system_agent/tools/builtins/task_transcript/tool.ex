defmodule OptimalSystemAgent.Tools.Builtins.TaskTranscript.Tool do
  @moduledoc """
  Read a subagent sidechain transcript.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.RunStore

  @impl true
  def name, do: "task_transcript"

  @impl true
  def aliases, do: ["agent_transcript", "subagent_transcript"]

  @impl true
  def search_hint, do: "read a subagent transcript"

  @impl true
  def description, do: "Read the sidechain transcript for a subagent run."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["agent_id"],
      "properties" => %{
        "agent_id" => %{"type" => "string", "description" => "Subagent id."}
      }
    }
  end

  @impl true
  def validate_input(%{"agent_id" => agent_id} = input, _ctx) when is_binary(agent_id),
    do: {:ok, input}

  def validate_input(%{"agent_id" => _}, _ctx), do: {:error, "agent_id must be a string", -32_602}
  def validate_input(_, _ctx), do: {:error, "Missing required parameter: agent_id", -32_602}

  @impl true
  def execute(%{"agent_id" => agent_id}, _ctx) do
    case RunStore.transcript(agent_id) do
      {:ok, transcript} -> {:ok, transcript}
      {:error, reason} -> {:ok, reason}
    end
  end

  @impl true
  def concurrency_safe?(_input, _ctx), do: true

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def to_classifier_input(%{"agent_id" => id}), do: %{agent_id: id}
end
