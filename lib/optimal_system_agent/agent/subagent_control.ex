defmodule OptimalSystemAgent.Agent.SubagentControl do
  @moduledoc """
  Operator control seam for delegated runs.

  It combines durable execution facts with the existing Loop, RunStore, and
  Orchestrator lifecycle primitives. HTTP, CLI, and TUI callers issue the same
  small set of commands and receive a fresh durable snapshot in response.
  """

  require Logger

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
      with {:ok, current} <- snapshot(agent_id),
           true <-
             action in current.available_controls ||
               {:error, {:invalid_action_for_status, action, current.status}},
           :ok <- apply_command(agent_id, action, params),
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
      Loop.cancel(agent_id)
    end

    with :ok <- await_stopped(agent_id, 100) do
      :ets.delete(:osa_agent_pause_flags, agent_id)
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

  defp await_stopped(_agent_id, 0), do: {:error, :pause_teardown_timeout}

  defp await_stopped(agent_id, attempts_left) do
    if alive?(agent_id) or runner_alive?(agent_id) or not RunStore.lease_claimable?(agent_id) do
      Process.sleep(10)
      await_stopped(agent_id, attempts_left - 1)
    else
      :ok
    end
  end

  defp runner_alive?(agent_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, Orchestrator.runner_key(agent_id)) != []
  rescue
    error ->
      Logger.error("[SubagentControl] runner lookup failed: #{Exception.message(error)}")
      true
  end

  defp alive?(agent_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) != []
  rescue
    error ->
      Logger.error("[SubagentControl] liveness lookup failed: #{Exception.message(error)}")
      false
  end

  @doc "Return the commands currently valid for a durable execution status."
  @spec available_controls(atom() | String.t()) :: [String.t()]
  def available_controls(status) do
    status = to_string(status)

    case status do
      "running" ->
        ~w(pause cancel_tool stop reassign)

      "paused" ->
        ~w(resume stop reassign)

      status when status in ["stalled", "interrupted"] ->
        ~w(retry resume stop reassign)

      _ ->
        ~w(retry resume reassign)
    end
  end

  defp add_controls(snapshot) do
    Map.put(
      snapshot,
      :available_controls,
      available_controls(Map.get(snapshot, :status, "unknown"))
    )
  end
end
