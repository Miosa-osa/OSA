defmodule OptimalSystemAgent.Speculative.Tools.StartSpeculative.Handler do
  @moduledoc """
  Validation and execution logic for `start_speculative`.

    * `validate/2`  — type-check predicted_next_task and assumptions
    * `execute/2`   — start the speculative executor, return speculative_id
  """

  alias OptimalSystemAgent.Speculative.Executor
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(
        %{"predicted_next_task" => task, "assumptions" => assumptions} = input,
        _ctx
      )
      when is_binary(task) and is_list(assumptions) do
    cond do
      Enum.empty?(assumptions) ->
        {:error, "assumptions must be a non-empty list of strings", -32_602}

      not Enum.all?(assumptions, &is_binary/1) ->
        non_str = Enum.find(assumptions, &(not is_binary(&1)))
        {:error, "All assumptions must be strings — got: #{inspect(non_str)}", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"predicted_next_task" => _, "assumptions" => assumptions}, _ctx)
      when not is_list(assumptions),
      do:
        {:error, "assumptions must be an array of strings — got: #{inspect(assumptions)}",
         -32_602}

  def validate(%{"assumptions" => _}, _ctx),
    do: {:error, "Missing required parameter: predicted_next_task", -32_602}

  def validate(%{"predicted_next_task" => _}, _ctx),
    do: {:error, "Missing required parameter: assumptions", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: predicted_next_task and assumptions", -32_602}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(
        %{"predicted_next_task" => task_desc, "assumptions" => assumptions} = params,
        _ctx
      ) do
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
