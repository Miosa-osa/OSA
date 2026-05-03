defmodule OptimalSystemAgent.Tools.Builtins.TaskWait.Tool do
  @moduledoc """
  Wait for a subagent run to leave the running state.
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Agent.RunStore

  @impl true
  def name, do: "task_wait"

  @impl true
  def aliases, do: ["agent_wait", "wait_agent"]

  @impl true
  def search_hint, do: "wait for a background subagent to complete"

  @impl true
  def description, do: "Wait for a subagent run to complete, fail, or be cancelled."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["agent_id"],
      "properties" => %{
        "agent_id" => %{"type" => "string", "description" => "Subagent id to wait for."},
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Maximum wait in milliseconds. Defaults to 30000."
        }
      }
    }
  end

  @impl true
  def validate_input(%{"agent_id" => agent_id} = input, _ctx) when is_binary(agent_id),
    do: {:ok, input}

  def validate_input(%{"agent_id" => _}, _ctx), do: {:error, "agent_id must be a string", -32_602}
  def validate_input(_, _ctx), do: {:error, "Missing required parameter: agent_id", -32_602}

  @impl true
  def execute(%{"agent_id" => agent_id} = input, _ctx) do
    timeout_ms = parse_timeout(Map.get(input, "timeout_ms"))
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case wait_until_done(agent_id, deadline) do
      {:ok, run} ->
        result =
          run.result ||
            %{
              agent_id: agent_id,
              parent_session_id: run.parent_session_id,
              role: run.role,
              status: run.status,
              summary: "",
              transcript_path: run.transcript_path
            }

        {:ok, RunStore.format_result(result)}

      {:timeout, run} when is_map(run) ->
        {:ok, "Agent #{agent_id} is still #{run.status} after #{timeout_ms}ms."}

      {:timeout, nil} ->
        {:ok, "Agent #{agent_id} was not found within #{timeout_ms}ms."}
    end
  end

  @impl true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def read_only?(_input, _ctx), do: true

  @impl true
  def interrupt_behavior, do: :cancel

  @impl true
  def to_classifier_input(%{"agent_id" => id}), do: %{agent_id: id}

  defp wait_until_done(agent_id, deadline) do
    case RunStore.get(agent_id) do
      %{status: :running} = run ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:timeout, run}
        else
          Process.sleep(min(100, remaining_ms))
          wait_until_done(agent_id, deadline)
        end

      run when is_map(run) ->
        {:ok, run}

      nil ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:timeout, nil}
        else
          Process.sleep(min(100, remaining_ms))
          wait_until_done(agent_id, deadline)
        end
    end
  end

  defp parse_timeout(value) when is_integer(value) and value > 0, do: min(value, 300_000)
  defp parse_timeout(_), do: 30_000
end
