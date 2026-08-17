defmodule OptimalSystemAgent.Agent.SubagentControl do
  @moduledoc """
  Operator control seam for delegated runs.

  It combines durable execution facts with the existing Loop, RunStore, and
  Orchestrator lifecycle primitives. HTTP, CLI, and TUI callers issue the same
  small set of commands and receive a fresh durable snapshot in response.
  """

  alias OptimalSystemAgent.Agent.{ExecutionControl, Loop, RunStore}
  alias OptimalSystemAgent.Orchestrator

  @actions ~w(pause resume retry reassign cancel_tool stop)

  @doc "Return the durable operator projection for one run."
  @spec snapshot(String.t()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(agent_id) when is_binary(agent_id) do
    case RunStore.get(agent_id) do
      nil ->
        case ExecutionControl.get(agent_id) do
          nil -> {:error, :not_found}
          control -> {:ok, add_controls(control)}
        end

      run ->
        {:ok, run |> ExecutionControl.project() |> add_controls()}
    end
  end

  @doc "Apply an operator action and return the resulting snapshot."
  @spec command(String.t(), String.t() | atom(), map()) ::
          {:ok, map()} | {:error, term()}
  def command(agent_id, action, params \\ %{}) when is_binary(agent_id) and is_map(params) do
    action = to_string(action)

    if action in @actions do
      with :ok <- apply_command(agent_id, action, params),
           {:ok, snapshot} <- snapshot(agent_id) do
        {:ok, snapshot}
      end
    else
      {:error, {:unsupported_action, action}}
    end
  end

  defp apply_command(agent_id, "pause", _params) do
    :ets.insert(:osa_agent_pause_flags, {agent_id, true})
    ExecutionControl.progress(agent_id, %{status: :paused, recovery_state: "operator_paused"})
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  defp apply_command(agent_id, "resume", params) do
    if alive?(agent_id) do
      :ets.delete(:osa_agent_pause_flags, agent_id)
      ExecutionControl.progress(agent_id, %{status: :running, recovery_state: "live_resumed"})
    else
      resume(agent_id, Map.get(params, "message") || Map.get(params, :message))
    end
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  defp apply_command(agent_id, "retry", params) do
    message =
      Map.get(params, "message") || Map.get(params, :message) ||
        "Retry the failed or stalled task from the last durable checkpoint. " <>
          "Change the approach that failed and finish the original assignment."

    resume(agent_id, message)
  end

  defp apply_command(agent_id, "cancel_tool", _params) do
    Loop.cancel(agent_id)

    ExecutionControl.progress(agent_id, %{
      status: :interrupted,
      current_tool: nil,
      recovery_state: "tool_cancelled_resume_available"
    })
  end

  defp apply_command(agent_id, "stop", _params) do
    Loop.cancel(agent_id)
    ExecutionControl.finish(agent_id, :cancelled, %{recovery_state: "stopped"})
  end

  defp apply_command(agent_id, "reassign", params) do
    with {:ok, current} <- snapshot(agent_id) do
      role = Map.get(params, "role") || Map.get(params, :role) || "agent"
      task = Map.get(params, "task") || Map.get(params, :task) || current.task

      config = %{
        task: task,
        parent_session_id: current.parent_session_id,
        role: role,
        provider: Map.get(params, "provider") || Map.get(params, :provider),
        model: Map.get(params, "model") || Map.get(params, :model),
        name: Map.get(params, "name") || Map.get(params, :name)
      }

      case Orchestrator.run_background(current.parent_session_id, config) do
        {:ok, replacement_id} ->
          ExecutionControl.finish(agent_id, :reassigned, %{
            replacement_agent_id: replacement_id,
            recovery_state: "reassigned"
          })

        error ->
          error
      end
    end
  end

  defp resume(agent_id, nil) do
    resume(agent_id, "Continue from the durable checkpoint and finish the original task.")
  end

  defp resume(agent_id, message), do: Orchestrator.resume_subagent(agent_id, message)

  defp alive?(agent_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) != []
  rescue
    _ -> false
  end

  defp add_controls(snapshot) do
    status = to_string(Map.get(snapshot, :status, "unknown"))

    controls =
      case status do
        status when status in ["running", "paused", "stalled", "interrupted"] ->
          ~w(pause resume cancel_tool stop reassign)

        _ ->
          ~w(retry resume reassign)
      end

    Map.put(snapshot, :available_controls, controls)
  end
end
