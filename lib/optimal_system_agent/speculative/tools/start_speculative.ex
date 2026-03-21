defmodule OptimalSystemAgent.Speculative.Tools.StartSpeculative do
  @moduledoc """
  Tool: start_speculative

  Allows an agent to begin working ahead on a predicted next task before it is
  formally assigned. If the prediction is correct and assumptions hold, the
  speculative work is promoted — eliminating re-work. If the prediction is
  wrong, all artifacts are discarded cleanly.

  ## Usage flow

  1. Agent calls `start_speculative` with `predicted_next_task` and `assumptions`
  2. Tool returns a `speculative_id`
  3. Agent performs work — file writes, decisions, message drafts — and updates
     the work product via `Executor.update_work_product/2`
  4. When the actual task arrives:
     - If it matches: call `Executor.check_assumptions/2` then `Executor.promote/1`
     - If it doesn't: call `Executor.discard/1`

  ## Parameters

  | Field                | Type           | Required | Description                                      |
  |----------------------|----------------|----------|--------------------------------------------------|
  | `predicted_next_task`| string         | yes      | Description of the task being worked ahead on    |
  | `assumptions`        | array[string]  | yes      | Conditions that must hold for work to be usable  |
  | `agent_id`           | string         | no       | Agent identifier (defaults to `"unknown"`)       |

  ## Example LLM call

      {
        "tool": "start_speculative",
        "parameters": {
          "predicted_next_task": "Implement JWT refresh token endpoint",
          "assumptions": [
            "User has not changed the auth architecture decision",
            "The refresh token schema migration has not been altered",
            "No other agent is already working on auth"
          ],
          "agent_id": "agent_phoenix_api"
        }
      }

  ## Returns (success)

      {
        "speculative_id": "spec_a1b2c3d4e5f6a7b8",
        "status": "running",
        "assumption_count": 3,
        "message": "Speculative execution started. Work ahead on predicted task. Call discard or promote when the real task arrives."
      }
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Speculative.Executor

  @impl true
  def name, do: "start_speculative"

  @impl true
  def description do
    "Begin speculative execution — work ahead on a predicted next task. Returns a speculative_id. " <>
      "If assumptions hold when the real task arrives, call promote to apply the work. " <>
      "If assumptions break, call discard to clean up without side effects."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "predicted_next_task" => %{
          "type" => "string",
          "description" => "Description of the task predicted to be assigned next. Be specific — this drives what gets worked on."
        },
        "assumptions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of conditions that must still be true when the real task arrives for this work to be valid. E.g. 'user_intent_unchanged', 'no conflicting PR merged'.",
          "minItems" => 1
        },
        "agent_id" => %{
          "type" => "string",
          "description" => "Identifier of the agent performing the speculative work. Optional — defaults to 'unknown'."
        }
      },
      "required" => ["predicted_next_task", "assumptions"]
    }
  end

  @impl true
  def safety, do: :write_safe

  @impl true
  def execute(%{"predicted_next_task" => task_desc, "assumptions" => assumptions} = params)
      when is_binary(task_desc) and is_list(assumptions) do
    if Enum.empty?(assumptions) do
      {:error, "assumptions must be a non-empty list of strings"}
    else
      non_string = Enum.find(assumptions, &(not is_binary(&1)))

      if non_string do
        {:error, "All assumptions must be strings — got: #{inspect(non_string)}"}
      else
        agent_id = Map.get(params, "agent_id", "unknown")

        predicted_task = %{
          description: task_desc,
          predicted_at: DateTime.to_iso8601(DateTime.utc_now())
        }

        case Executor.start_speculative(agent_id, predicted_task, assumptions) do
          {:ok, spec_id} ->
            result = %{
              "speculative_id" => spec_id,
              "status" => "running",
              "assumption_count" => length(assumptions),
              "message" =>
                "Speculative execution started. Perform work ahead on the predicted task. " <>
                  "When the real task arrives: if it matches and assumptions hold, call promote. " <>
                  "If it doesn't match or assumptions broke, call discard."
            }

            {:ok, Jason.encode!(result)}

          {:error, reason} ->
            {:error, "Failed to start speculative execution: #{inspect(reason)}"}
        end
      end
    end
  end

  def execute(%{"predicted_next_task" => _task, "assumptions" => assumptions})
      when not is_list(assumptions) do
    {:error, "assumptions must be an array of strings — got: #{inspect(assumptions)}"}
  end

  def execute(%{"assumptions" => _}) do
    {:error, "Missing required parameter: predicted_next_task"}
  end

  def execute(%{"predicted_next_task" => _}) do
    {:error, "Missing required parameter: assumptions"}
  end

  def execute(_) do
    {:error, "Missing required parameters: predicted_next_task and assumptions"}
  end
end
