defmodule OptimalSystemAgent.Agent.Orchestrator.WaveExecutor do
  @moduledoc """
  Pure helper functions for wave-based task execution in the Orchestrator.

  Extracted from `Orchestrator` to keep GenServer callbacks thin.
  Contains result recording, ref-lookup, and synthesis logic that
  operate on Orchestrator state maps without needing GenServer state directly.
  """

  require Logger

  alias OptimalSystemAgent.Agent.TaskQueue
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  # ── Ref Lookup ──────────────────────────────────────────────────────

  @doc """
  Find which task owns a given Task.async ref.

  Returns `{task_id, agent_name, agent_id, subtask_id}` or `nil`.
  """
  @spec find_task_by_ref(reference(), map()) ::
          {String.t(), String.t(), String.t(), String.t()} | nil
  def find_task_by_ref(ref, tasks) do
    Enum.find_value(tasks, fn {task_id, task_state} ->
      case Map.get(task_state.wave_refs, ref) do
        {agent_name, agent_id, subtask_id} ->
          {task_id, agent_name, agent_id, subtask_id}

        nil ->
          nil
      end
    end)
  end

  # ── Agent Result Recording ───────────────────────────────────────────

  @doc """
  Record an agent's result: update agent state, wave_refs, results map, TaskQueue.

  Returns the updated top-level `state` map (with `:tasks` key).
  """
  @spec record_agent_result(
          map(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          term()
        ) :: map()
  def record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, raw_result) do
    task_state = Map.get(state.tasks, task_id)

    # Derive status, result, and error from raw_result
    {status, agent_result, error} =
      case raw_result do
        {:ok, text} -> {:completed, text, nil}
        {:error, reason} -> {:failed, nil, reason}
        text when is_binary(text) -> {:completed, text, nil}
      end

    updated_agent =
      case Map.get(task_state.agents, agent_id) do
        nil -> nil
        agent ->
          %{agent | status: status, result: agent_result, error: error, completed_at: DateTime.utc_now()}
      end

    updated_agents =
      if updated_agent,
        do: Map.put(task_state.agents, agent_id, updated_agent),
        else: task_state.agents

    # Remove ref from wave_refs and store result
    wave_refs = Map.reject(task_state.wave_refs, fn {_ref, {name, _, _}} -> name == agent_name end)

    task_state = %{
      task_state
      | agents: updated_agents,
        wave_refs: wave_refs,
        results: Map.put(task_state.results, agent_name, result_text)
    }

    # TaskQueue complete/fail (best-effort)
    try do
      case status do
        :completed -> TaskQueue.complete(subtask_id, result_text)
        :failed -> TaskQueue.fail(subtask_id, error || result_text)
      end
    catch
      :exit, _ -> :ok
    end

    Bus.emit(:system_event, %{
      event: :orchestrator_agent_completed,
      task_id: task_id,
      session_id: task_state.session_id,
      agent_id: agent_id,
      agent_name: agent_name,
      status: status
    })

    # Emit task_updated so the TUI reflects the final state of this subtask.
    status_str = if status == :completed, do: "completed", else: "failed"

    Bus.emit(:system_event, %{
      event: :task_updated,
      task_id: subtask_id,
      status: status_str,
      session_id: task_state.session_id
    })

    %{state | tasks: Map.put(state.tasks, task_id, task_state)}
  end

  # ── Result Synthesis ────────────────────────────────────────────────

  @doc """
  Synthesize results from all agents into a single response string.

  Calls the LLM to produce a unified summary, falling back to a
  simple join if the call fails.
  """
  @spec synthesize_results(String.t(), map(), String.t(), String.t()) :: String.t()
  def synthesize_results(task_id, results, original_message, session_id) do
    if map_size(results) == 0 do
      "No agents produced results."
    else
      agent_outputs =
        Enum.map(results, fn {name, result} ->
          "## Agent: #{name}\n#{result}"
        end)
        |> Enum.join("\n\n---\n\n")

      prompt = """
      You are synthesizing the work of multiple agents. The original task was:
      "#{String.slice(original_message, 0, 500)}"

      Here are the results from each agent:

      #{agent_outputs}

      Provide a unified response that:
      1. Summarizes what was accomplished
      2. Lists any files created or modified
      3. Notes any issues or follow-up items
      4. Gives a clear status: COMPLETE, PARTIAL, or FAILED
      """

      Bus.emit(:system_event, %{
        event: :orchestrator_synthesizing,
        task_id: task_id,
        session_id: session_id,
        agent_count: map_size(results)
      })

      try do
        case Providers.chat([%{role: "user", content: prompt}],
               temperature: 0.3,
               max_tokens: 2000
             ) do
          {:ok, %{content: synthesis}} when is_binary(synthesis) and synthesis != "" ->
            synthesis

          _ ->
            Logger.warning(
              "[WaveExecutor] Synthesis LLM call failed -- falling back to joined results"
            )

            Enum.map_join(results, "\n\n---\n\n", fn {name, result} ->
              "## #{name}\n#{result}"
            end)
        end
      rescue
        e ->
          Logger.error("[WaveExecutor] Synthesis failed: #{Exception.message(e)}")

          Enum.map_join(results, "\n\n---\n\n", fn {name, result} ->
            "## #{name}\n#{result}"
          end)
      end
    end
  end
end
