defmodule OptimalSystemAgent.Swarm.Orchestrator do
  @moduledoc """
  Coordinates multi-agent swarm execution.

  When a task is too complex for a single agent, the Orchestrator:
  1. Decomposes the task into subtasks via `Planner.decompose/2`
  2. Spawns role-specific Worker processes under `Swarm.AgentPool`
  3. Creates an isolated Mailbox partition for inter-agent communication
  4. Executes the chosen pattern (parallel / pipeline / debate / review)
  5. Synthesises all agent results into a cohesive final answer
  6. Emits events on `Events.Bus` at each lifecycle transition

  ## Limits
  - Max 10 concurrent swarms
  - Max 5 agents per swarm
  - Default timeout 5 minutes (configurable per launch via `:timeout_ms` opt)

  ## Swarm lifecycle
    :running → :completed | :failed | :cancelled | :timeout

  ## Event emissions
    - `system_event` with `%{event: :swarm_started, ...}`
    - `system_event` with `%{event: :swarm_completed, ...}`
    - `system_event` with `%{event: :swarm_failed, ...}`
    - `system_event` with `%{event: :swarm_cancelled, ...}`
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Swarm.{Worker, Mailbox, Planner, Patterns}
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Events.Bus

  @max_swarms 10
  @max_agents 10
  # 5 minutes
  @default_timeout_ms 300_000
  @valid_patterns [:parallel, :pipeline, :debate, :review]

  defstruct swarms: %{},
            active_count: 0

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Launch a new swarm for a complex task.

  Options:
    - `:pattern`    — override automatic pattern selection (:parallel | :pipeline | :debate | :review)
    - `:timeout_ms` — swarm-level timeout in ms (default: #{@default_timeout_ms})
    - `:max_agents` — cap the number of agents (default: #{@max_agents})

  Returns `{:ok, swarm_id}` or `{:error, reason}`.
  """
  def launch(task, opts \\ []) do
    GenServer.call(__MODULE__, {:launch, task, opts}, :infinity)
  end

  @doc "Get status and metadata of a running or completed swarm."
  def status(swarm_id) do
    GenServer.call(__MODULE__, {:status, swarm_id})
  end

  @doc "Cancel a running swarm. Workers are terminated immediately."
  def cancel(swarm_id) do
    GenServer.call(__MODULE__, {:cancel, swarm_id})
  end

  @doc "List all swarms (active and recently completed)."
  def list_swarms do
    GenServer.call(__MODULE__, :list_swarms)
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(state) do
    Logger.info("Swarm orchestrator started (max_swarms=#{@max_swarms})")
    {:ok, state}
  end

  @impl true
  def handle_call({:launch, task, opts}, _from, state) do
    cond do
      state.active_count >= @max_swarms ->
        {:reply, {:error, "Max concurrent swarms (#{@max_swarms}) reached"}, state}

      String.trim(task) == "" ->
        {:reply, {:error, "Task description cannot be empty"}, state}

      true ->
        do_launch(task, opts, state)
    end
  end

  @impl true
  def handle_call({:status, swarm_id}, _from, state) do
    case Map.get(state.swarms, swarm_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      swarm ->
        {:reply, {:ok, swarm_to_public(swarm)}, state}
    end
  end

  @impl true
  def handle_call({:cancel, swarm_id}, _from, state) do
    case Map.get(state.swarms, swarm_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{status: status} when status not in [:running] ->
        {:reply, {:error, "Swarm is not running (status: #{status})"}, state}

      swarm ->
        terminate_workers(swarm.workers)
        Mailbox.clear(swarm_id)

        updated = %{swarm | status: :cancelled, completed_at: DateTime.utc_now()}
        new_count = max(0, state.active_count - 1)

        state = %{
          state
          | swarms: Map.put(state.swarms, swarm_id, updated),
            active_count: new_count
        }

        Bus.emit(:system_event, %{event: :swarm_cancelled, swarm_id: swarm_id})
        Logger.info("Swarm #{swarm_id} cancelled")

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:list_swarms, _from, state) do
    swarms =
      state.swarms
      |> Map.values()
      |> Enum.map(&swarm_to_public/1)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    {:reply, {:ok, swarms}, state}
  end

  @impl true
  def handle_cast({:swarm_complete, swarm_id, results}, state) do
    case Map.get(state.swarms, swarm_id) do
      nil ->
        {:noreply, state}

      swarm ->
        orchestrator = self()

        Task.start(fn ->
          synthesis = synthesise(swarm.task, swarm.plan, results)
          GenServer.cast(orchestrator, {:synthesis_complete, swarm_id, results, synthesis})
        end)

        swarms = Map.put(state.swarms, swarm_id, %{swarm | status: :synthesizing})
        {:noreply, %{state | swarms: swarms}}
    end
  end

  @impl true
  def handle_cast({:synthesis_complete, swarm_id, results, final_result}, state) do
    case Map.get(state.swarms, swarm_id) do
      nil ->
        {:noreply, state}

      swarm ->
        updated = %{
          swarm
          | status: :completed,
            result: final_result,
            agent_results: results,
            completed_at: DateTime.utc_now()
        }

        new_count = max(0, state.active_count - 1)

        state = %{
          state
          | swarms: Map.put(state.swarms, swarm_id, updated),
            active_count: new_count
        }

        Mailbox.clear(swarm_id)

        Bus.emit(:system_event, %{
          event: :swarm_completed,
          swarm_id: swarm_id,
          pattern: swarm.plan.pattern,
          agent_count: length(results),
          result_preview: String.slice(final_result || "", 0, 200)
        })

        Logger.info("Swarm #{swarm_id} completed (#{length(results)} agents)")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:swarm_failed, swarm_id, reason}, state) do
    case Map.get(state.swarms, swarm_id) do
      nil ->
        {:noreply, state}

      swarm ->
        updated = %{
          swarm
          | status: :failed,
            error: inspect(reason),
            completed_at: DateTime.utc_now()
        }

        new_count = max(0, state.active_count - 1)

        state = %{
          state
          | swarms: Map.put(state.swarms, swarm_id, updated),
            active_count: new_count
        }

        Mailbox.clear(swarm_id)

        Bus.emit(:system_event, %{
          event: :swarm_failed,
          swarm_id: swarm_id,
          reason: inspect(reason)
        })

        Logger.error("Swarm #{swarm_id} failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, swarm_id}, state) do
    case Map.get(state.swarms, swarm_id) do
      %{status: :running} = swarm ->
        Logger.warning("Swarm #{swarm_id} timed out — terminating workers")
        terminate_workers(swarm.workers)
        Mailbox.clear(swarm_id)

        updated = %{swarm | status: :timeout, completed_at: DateTime.utc_now()}
        new_count = max(0, state.active_count - 1)

        state = %{
          state
          | swarms: Map.put(state.swarms, swarm_id, updated),
            active_count: new_count
        }

        Bus.emit(:system_event, %{event: :swarm_timeout, swarm_id: swarm_id})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # ── Launch Logic ─────────────────────────────────────────────────────

  defp do_launch(task, opts, state) do
    # 0. Validate pattern early — reject unknown patterns before spawning anything
    if Keyword.has_key?(opts, :pattern) do
      pattern = Keyword.get(opts, :pattern)

      if pattern not in @valid_patterns do
        valid_str = @valid_patterns |> Enum.map_join(", ", &to_string/1)

        {:reply,
         {:error,
          "Unknown swarm pattern: #{inspect(pattern)}. Valid patterns: #{valid_str}"},
         state}
      else
        do_launch_validated(task, opts, state)
      end
    else
      do_launch_validated(task, opts, state)
    end
  end

  defp do_launch_validated(task, opts, state) do
    swarm_id = generate_id()
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_agents = Keyword.get(opts, :max_agents, @max_agents)

    # 1. Decompose task into a plan (LLM-powered, with fallback)
    plan =
      if Keyword.has_key?(opts, :pattern) do
        # Caller provided an override pattern — still use planner for agents
        base = Planner.decompose(task, max_agents: max_agents)
        %{base | pattern: Keyword.get(opts, :pattern)}
      else
        Planner.decompose(task, max_agents: max_agents)
      end

    # 2. Start workers under DynamicSupervisor
    workers =
      Enum.map(plan.agents, fn agent_spec ->
        worker_id = generate_id()
        init_opts = %{id: worker_id, swarm_id: swarm_id, role: agent_spec.role}

        case DynamicSupervisor.start_child(
               OptimalSystemAgent.Swarm.AgentPool,
               {Worker, init_opts}
             ) do
          {:ok, pid} ->
            {agent_spec, pid}

          {:error, reason} ->
            Logger.error("Failed to start worker for role #{agent_spec.role}: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if workers == [] do
      {:reply, {:error, "Failed to start any workers"}, state}
    else
      # 3. Create mailbox partition
      Mailbox.create(swarm_id)

      # 4. Schedule timeout
      Process.send_after(self(), {:timeout, swarm_id}, timeout_ms)

      # 5. Execute pattern asynchronously
      orchestrator = self()

      Task.start(fn ->
        try do
          results =
            case plan.pattern do
              :parallel ->
                Patterns.parallel(workers, plan.agents, swarm_id)

              :pipeline ->
                Patterns.pipeline(workers, plan.agents, swarm_id)

              :debate ->
                Patterns.debate(workers, plan.agents, swarm_id)

              :review ->
                Patterns.review_loop(workers, plan.agents, swarm_id)

              other ->
                raise "Invalid swarm pattern #{inspect(other)} reached execution — this should have been caught by validation"
            end

          GenServer.cast(orchestrator, {:swarm_complete, swarm_id, results})
        rescue
          e ->
            GenServer.cast(orchestrator, {:swarm_failed, swarm_id, e})
        end
      end)

      swarm_state = %{
        id: swarm_id,
        task: task,
        plan: plan,
        workers: workers,
        status: :running,
        result: nil,
        agent_results: [],
        error: nil,
        started_at: DateTime.utc_now(),
        completed_at: nil,
        timeout_ms: timeout_ms
      }

      new_state = %{
        state
        | swarms: Map.put(state.swarms, swarm_id, swarm_state),
          active_count: state.active_count + 1
      }

      Bus.emit(:system_event, %{
        event: :swarm_started,
        swarm_id: swarm_id,
        pattern: plan.pattern,
        agent_count: length(workers),
        task_preview: String.slice(task, 0, 200)
      })

      Logger.info("Swarm #{swarm_id} launched: pattern=#{plan.pattern} agents=#{length(workers)}")

      {:reply, {:ok, swarm_id}, new_state}
    end
  end

  # ── Result Synthesis ─────────────────────────────────────────────────

  # Use an LLM call to produce a final cohesive answer from all agent results.
  # Falls back to joining results with separators if the LLM fails.
  defp synthesise(original_task, plan, results) do
    successful = Enum.filter(results, &(&1.status == :done and not is_nil(&1.result)))

    if successful == [] do
      "All agents failed to produce results."
    else
      agent_outputs =
        successful
        |> Enum.with_index(1)
        |> Enum.map(fn {%{role: role, task: task, result: text}, i} ->
          "### Agent #{i} (#{role})\nTask: #{task}\n\nOutput:\n#{text}"
        end)
        |> Enum.join("\n\n---\n\n")

      synthesis_prompt = """
      You are synthesising the outputs of a multi-agent swarm into a single, cohesive
      final answer. Do NOT mention the swarm structure or agents in your response —
      just produce the best possible answer to the original task.

      ## Original task
      #{original_task}

      ## Execution pattern used
      #{plan.pattern} (synthesis: #{plan.synthesis_strategy})

      ## Agent outputs

      #{agent_outputs}

      ## Instructions
      Combine the best elements of all agent outputs into a comprehensive, well-structured
      final response. Eliminate redundancy. Resolve contradictions by choosing the more
      accurate/complete version. Your response IS the final answer — make it complete.
      """

      messages = [
        %{
          role: "system",
          content:
            "You are an expert synthesiser. Combine multi-agent outputs into a single best answer."
        },
        %{role: "user", content: synthesis_prompt}
      ]

      case Providers.chat(messages, temperature: 0.4) do
        {:ok, %{content: text}} when is_binary(text) and text != "" ->
          text

        _ ->
          # Fallback: join all results
          Logger.warning("Synthesis LLM call failed — falling back to joined results")

          Enum.map_join(successful, "\n\n---\n\n", fn %{role: role, result: text} ->
            "## #{role}\n#{text}"
          end)
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp terminate_workers(workers) do
    Enum.each(workers, fn {_spec, pid} ->
      if is_pid(pid) and Process.alive?(pid) do
        DynamicSupervisor.terminate_child(OptimalSystemAgent.Swarm.AgentPool, pid)
      end
    end)
  end

  defp swarm_to_public(swarm) do
    %{
      id: swarm.id,
      status: swarm.status,
      task: swarm.task,
      pattern: swarm[:plan] && swarm.plan.pattern,
      agent_count: length(swarm[:workers] || []),
      agents:
        swarm[:plan] && Enum.map(swarm.plan.agents, fn a -> %{role: a.role, task: a.task} end),
      result: swarm[:result],
      error: swarm[:error],
      started_at: swarm.started_at,
      completed_at: swarm[:completed_at]
    }
  end

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate("swarm")
end
