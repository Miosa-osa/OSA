defmodule OptimalSystemAgent.Agent.Orchestrator do
  @moduledoc """
  Autonomous task orchestration engine.

  When a complex task arrives, the orchestrator:
  1. Analyzes complexity (simple -> single agent, complex -> multi-agent)
  2. Decomposes into parallel sub-tasks
  3. Spawns sub-agents with specialized prompts
  4. Tracks real-time progress (tool uses, tokens, status)
  5. Synthesizes results from all sub-agents
  6. Can dynamically create new skills when existing ones are insufficient

  This is what makes OSA feel like a team of engineers, not a chatbot.

  Progress events are emitted on the event bus so UIs can show:
  Running 3 agents...
     Research agent - 12 tool uses - 45.2k tokens
     Build agent - 28 tool uses - 89.1k tokens
     Test agent - 8 tool uses - 23.4k tokens
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.{Appraiser, Roster, Tier, TaskQueue}
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Tools.Registry, as: Tools

  defstruct tasks: %{},
            agent_pool: %{},
            skill_cache: %{}

  # ── Sub-task struct ──────────────────────────────────────────────────

  defmodule SubTask do
    @moduledoc "A decomposed sub-task to be executed by a sub-agent."
    defstruct [
      :name,
      :description,
      :role,
      :tools_needed,
      depends_on: [],
      context: nil
    ]
  end

  defmodule AgentState do
    @moduledoc "Runtime state for a single sub-agent."
    defstruct [
      :id,
      :task_id,
      :name,
      :role,
      status: :pending,
      tool_uses: 0,
      tokens_used: 0,
      current_action: nil,
      started_at: nil,
      completed_at: nil,
      result: nil,
      error: nil
    ]
  end

  defmodule TaskState do
    @moduledoc "State for an orchestrated task."
    defstruct [
      :id,
      :message,
      :session_id,
      :strategy,
      status: :running,
      agents: %{},
      sub_tasks: [],
      results: %{},
      synthesis: nil,
      started_at: nil,
      completed_at: nil,
      error: nil,
      # Non-blocking execution state
      wave_refs: %{},
      current_wave: 0,
      pending_waves: [],
      cached_tools: []
    ]
  end

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Analyze a message and decide how to handle it.
  Returns :simple or {:complex, plan} where plan is a list of sub-tasks.
  """
  @spec analyze(String.t(), keyword()) :: :simple | {:complex, list()}
  def analyze(message, opts \\ []) do
    GenServer.call(__MODULE__, {:analyze, message, opts}, 60_000)
  end

  @doc """
  Execute a complex task with multiple sub-agents.
  Returns {:ok, task_id} immediately — execution proceeds asynchronously
  via handle_continue. Poll progress/1 or subscribe to
  :orchestrator_task_completed events for results.
  """
  @spec execute(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute(message, session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:execute, message, session_id, opts}, 60_000)
  end

  @doc """
  Get real-time progress for a running task.
  Returns agent statuses, tool use counts, token usage.
  """
  @spec progress(String.t()) :: {:ok, map()} | {:error, :not_found}
  def progress(task_id) do
    GenServer.call(__MODULE__, {:progress, task_id})
  end

  @doc """
  Dynamically create a new skill for a specific task.
  Writes a SKILL.md file and registers it with the Tools.Registry.
  """
  @spec create_skill(String.t(), String.t(), String.t(), list()) ::
          {:ok, String.t()} | {:error, term()}
  def create_skill(name, description, instructions, tools \\ []) do
    GenServer.call(__MODULE__, {:create_skill, name, description, instructions, tools})
  end

  @doc """
  List all tasks (running and recently completed).
  """
  @spec list_tasks() :: list(map())
  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  @doc """
  Search existing skills before creating new ones.
  Takes a task description and returns matching skills with relevance scores.
  """
  @spec find_matching_skills(String.t()) :: {:matches, list(map())} | :no_matches
  def find_matching_skills(task_description) do
    GenServer.call(__MODULE__, {:find_matching_skills, task_description})
  end

  @doc """
  Suggest existing skills or create a new one.
  First checks for matching skills. If matches with relevance > 0.5 exist,
  returns them for user confirmation. Otherwise creates the new skill.
  """
  @spec suggest_or_create_skill(String.t(), String.t(), String.t(), list()) ::
          {:existing_matches, list(map())} | {:created, String.t()} | {:error, term()}
  def suggest_or_create_skill(name, description, instructions, tools \\ []) do
    GenServer.call(__MODULE__, {:suggest_or_create, name, description, instructions, tools})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(state) do
    Logger.info(
      "[Orchestrator] Task orchestration engine started (max_agents=#{Roster.max_agents()})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:analyze, message, _opts}, _from, state) do
    result =
      try do
        analyze_complexity(message)
      rescue
        e ->
          Logger.error("[Orchestrator] Complexity analysis failed: #{Exception.message(e)}")
          :simple
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:execute, message, session_id, opts}, _from, state) do
    task_id = generate_id("task")
    strategy = Keyword.get(opts, :strategy, "auto")
    # Tools may be pre-cached by the caller to avoid GenServer deadlock
    cached_tools = Keyword.get(opts, :cached_tools, [])

    Bus.emit(:system_event, %{
      event: :orchestrator_task_started,
      task_id: task_id,
      message_preview: String.slice(message, 0, 200)
    })

    # Decompose is sync (needs LLM), but execution is async via handle_continue
    case decompose_task(message) do
      {:ok, sub_tasks} when is_list(sub_tasks) and length(sub_tasks) > 0 ->
        sub_tasks = Enum.take(sub_tasks, Roster.max_agents())

        # Estimate task value via Appraiser (best-effort)
        appraisal =
          try do
            estimates =
              Enum.map(sub_tasks, fn st ->
                role = st.role || :backend
                %{role: role, complexity: length(st.depends_on) + 3}
              end)

            Appraiser.estimate_task(estimates)
          rescue
            _ -> nil
          end

        if appraisal do
          Bus.emit(:system_event, %{
            event: :orchestrator_task_appraised,
            task_id: task_id,
            estimated_cost_usd: appraisal.total_cost_usd,
            estimated_hours: appraisal.total_hours
          })
        end

        # Enqueue sub-tasks into TaskQueue (best-effort)
        try do
          Enum.each(sub_tasks, fn st ->
            subtask_id = "#{task_id}_#{st.name}"

            TaskQueue.enqueue(subtask_id, session_id, %{
              name: st.name,
              role: st.role,
              description: st.description,
              depends_on: st.depends_on
            })
          end)
        catch
          :exit, _ -> :ok
        end

        task_state = %TaskState{
          id: task_id,
          message: message,
          session_id: session_id,
          strategy: strategy,
          status: :running,
          sub_tasks: sub_tasks,
          started_at: DateTime.utc_now(),
          cached_tools: cached_tools
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

        Bus.emit(:system_event, %{
          event: :orchestrator_agents_spawning,
          task_id: task_id,
          agent_count: length(sub_tasks),
          agents: Enum.map(sub_tasks, fn st -> %{name: st.name, role: st.role} end)
        })

        # Reply immediately, continue execution asynchronously
        {:reply, {:ok, task_id}, state,
         {:continue, {:start_execution, task_id}}}

      {:ok, []} ->
        Logger.warning(
          "[Orchestrator] Task decomposition returned no sub-tasks, running as simple"
        )

        result = run_simple(message, session_id)

        task_state = %TaskState{
          id: task_id,
          message: message,
          session_id: session_id,
          strategy: strategy,
          status: :completed,
          synthesis: result,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

        Bus.emit(:system_event, %{
          event: :orchestrator_task_completed,
          task_id: task_id,
          agent_count: 0,
          result_preview: String.slice(result || "", 0, 200)
        })

        {:reply, {:ok, task_id}, state}

      {:error, reason} ->
        Logger.error("[Orchestrator] Task decomposition failed: #{inspect(reason)}")

        Bus.emit(:system_event, %{
          event: :orchestrator_task_failed,
          task_id: task_id,
          reason: inspect(reason)
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:progress, task_id}, _from, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task_state ->
        progress = %{
          task_id: task_id,
          status: task_state.status,
          started_at: task_state.started_at,
          completed_at: task_state.completed_at,
          agents:
            task_state.agents
            |> Map.values()
            |> Enum.sort_by(& (&1.started_at || DateTime.utc_now()))
            |> Enum.map(fn agent ->
              %{
                id: agent.id,
                name: agent.name,
                role: agent.role,
                status: agent.status,
                tool_uses: agent.tool_uses,
                tokens_used: agent.tokens_used,
                current_action: agent.current_action,
                started_at: agent.started_at,
                completed_at: agent.completed_at
              }
            end),
          synthesis: task_state.synthesis,
          error: task_state.error
        }

        {:reply, {:ok, progress}, state}
    end
  end

  @impl true
  def handle_call({:create_skill, name, description, instructions, tools}, _from, state) do
    result = do_create_skill(name, description, instructions, tools)

    state =
      case result do
        {:ok, _} ->
          %{
            state
            | skill_cache:
                Map.put(state.skill_cache, name, %{
                  description: description,
                  created_at: DateTime.utc_now()
                })
          }

        _ ->
          state
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.map(fn t ->
        agent_count = map_size(t.agents)
        completed_count = t.agents |> Map.values() |> Enum.count(&(&1.status == :completed))

        %{
          id: t.id,
          status: t.status,
          message_preview: String.slice(t.message || "", 0, 100),
          agent_count: agent_count,
          completed_agents: completed_count,
          started_at: t.started_at,
          completed_at: t.completed_at
        }
      end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:find_matching_skills, task_description}, _from, state) do
    result = do_find_matching_skills(task_description)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:suggest_or_create, name, description, instructions, tools}, _from, state) do
    case do_find_matching_skills(description) do
      {:matches, matches} ->
        high_relevance = Enum.filter(matches, fn m -> m.relevance > 0.5 end)

        if high_relevance != [] do
          Logger.info(
            "[Orchestrator] Found #{length(high_relevance)} existing skill(s) matching '#{name}'"
          )

          {:reply, {:existing_matches, high_relevance}, state}
        else
          # Low relevance matches only — proceed to create
          result = do_create_skill(name, description, instructions, tools)

          state =
            case result do
              {:ok, _} ->
                %{
                  state
                  | skill_cache:
                      Map.put(state.skill_cache, name, %{
                        description: description,
                        created_at: DateTime.utc_now()
                      })
                }

              _ ->
                state
            end

          case result do
            {:ok, _} -> {:reply, {:created, name}, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        end

      :no_matches ->
        result = do_create_skill(name, description, instructions, tools)

        state =
          case result do
            {:ok, _} ->
              %{
                state
                | skill_cache:
                    Map.put(state.skill_cache, name, %{
                      description: description,
                      created_at: DateTime.utc_now()
                    })
              }

            _ ->
              state
          end

        case result do
          {:ok, _} -> {:reply, {:created, name}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # Handle progress updates from sub-agents via cast
  @impl true
  def handle_cast({:agent_progress, task_id, agent_id, update}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        case Map.get(task_state.agents, agent_id) do
          nil ->
            {:noreply, state}

          agent ->
            updated_agent = %{
              agent
              | tool_uses: Map.get(update, :tool_uses, agent.tool_uses),
                tokens_used: Map.get(update, :tokens_used, agent.tokens_used),
                current_action: Map.get(update, :current_action, agent.current_action)
            }

            updated_agents = Map.put(task_state.agents, agent_id, updated_agent)
            updated_task = %{task_state | agents: updated_agents}
            state = %{state | tasks: Map.put(state.tasks, task_id, updated_task)}

            Bus.emit(:system_event, %{
              event: :orchestrator_agent_progress,
              task_id: task_id,
              agent_id: agent_id,
              agent_name: agent.name,
              tool_uses: updated_agent.tool_uses,
              tokens_used: updated_agent.tokens_used,
              current_action: updated_agent.current_action
            })

            {:noreply, state}
        end
    end
  end

  # ── Handle Continue — Non-blocking wave execution ──────────────────

  @impl true
  def handle_continue({:start_execution, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        waves = build_execution_waves(task_state.sub_tasks)
        task_state = %{task_state | pending_waves: waves, current_wave: 0}
        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}
        {:noreply, state, {:continue, {:execute_wave, task_id}}}
    end
  end

  @impl true
  def handle_continue({:execute_wave, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      %{pending_waves: []} ->
        {:noreply, state, {:continue, {:synthesize, task_id}}}

      %{pending_waves: [wave | rest]} = task_state ->
        total_waves = task_state.current_wave + 1 + length(rest)

        Bus.emit(:system_event, %{
          event: :orchestrator_wave_started,
          task_id: task_id,
          wave_number: task_state.current_wave + 1,
          total_waves: total_waves,
          agent_count: length(wave)
        })

        session_id = task_state.session_id
        cached_tools = task_state.cached_tools

        # Spawn all agents in this wave, collecting refs and agent states
        spawn_results =
          Enum.map(wave, fn sub_task ->
            dep_context = build_dependency_context(sub_task.depends_on, task_state.results)
            sub_task_with_context = %{sub_task | context: dep_context}

            {agent_id, agent_state, task_ref} =
              spawn_agent(sub_task_with_context, task_id, session_id, cached_tools)

            subtask_id = "#{task_id}_#{sub_task.name}"
            {agent_id, agent_state, task_ref, sub_task.name, subtask_id}
          end)

        # Build wave_refs map: monitor_ref => {agent_name, agent_id, subtask_id}
        wave_refs =
          Enum.reduce(spawn_results, %{}, fn {agent_id, _as, task_ref, name, subtask_id}, refs ->
            Map.put(refs, task_ref.ref, {name, agent_id, subtask_id})
          end)

        # Register all agents into task state
        updated_agents =
          Enum.reduce(spawn_results, task_state.agents, fn {agent_id, agent_state, _, _, _}, agents ->
            Map.put(agents, agent_id, agent_state)
          end)

        task_state = %{
          task_state
          | pending_waves: rest,
            current_wave: task_state.current_wave + 1,
            wave_refs: wave_refs,
            agents: updated_agents
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue({:synthesize, task_id}, state) do
    case Map.get(state.tasks, task_id) do
      nil ->
        {:noreply, state}

      task_state ->
        synthesis = synthesize_results(task_id, task_state.results, task_state.message)

        task_state = %{
          task_state
          | status: :completed,
            synthesis: synthesis,
            completed_at: DateTime.utc_now()
        }

        state = %{state | tasks: Map.put(state.tasks, task_id, task_state)}

        Bus.emit(:system_event, %{
          event: :orchestrator_task_completed,
          task_id: task_id,
          agent_count: map_size(task_state.agents),
          result_preview: String.slice(synthesis || "", 0, 200)
        })

        Logger.info(
          "[Orchestrator] Task #{task_id} completed — #{map_size(task_state.agents)} agents, synthesis ready"
        )

        {:noreply, state}
    end
  end

  # ── Handle Info — Task.async completion / crash messages ────────────

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task.async completion — demonitor and flush the :DOWN message
    Process.demonitor(ref, [:flush])

    case find_task_by_ref(ref, state) do
      nil ->
        {:noreply, state}

      {task_id, agent_name, agent_id, subtask_id} ->
        result_text =
          case result do
            {:ok, text} -> text
            {:error, reason} -> "FAILED: #{reason}"
            text when is_binary(text) -> text
          end

        state = record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, result)

        # Check if all agents in current wave are done
        task_state = Map.get(state.tasks, task_id)

        if map_size(task_state.wave_refs) == 0 do
          {:noreply, state, {:continue, {:execute_wave, task_id}}}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_task_by_ref(ref, state) do
      nil ->
        {:noreply, state}

      {task_id, agent_name, agent_id, subtask_id} ->
        result_text = "FAILED: Agent crashed: #{inspect(reason)}"
        state = record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, {:error, result_text})

        task_state = Map.get(state.tasks, task_id)

        if map_size(task_state.wave_refs) == 0 do
          {:noreply, state, {:continue, {:execute_wave, task_id}}}
        else
          {:noreply, state}
        end
    end
  end

  # ── Complexity Analysis ─────────────────────────────────────────────

  defp analyze_complexity(message) do
    prompt = """
    Analyze this task's complexity. Respond ONLY with valid JSON, no markdown fences.

    Task: "#{String.slice(message, 0, 500)}"

    Determine:
    1. complexity: "simple" (one agent can handle) or "complex" (needs multiple parallel agents)
    2. If complex, decompose into parallel sub-tasks (max #{Roster.max_agents()})
    3. For each sub-task, specify:
       - name: short identifier (snake_case)
       - description: what this agent should do
       - role: one of the 9 specialist roles below
       - tools_needed: which skills this agent needs (file_read, file_write, shell_execute, web_search, memory_save)
       - depends_on: list of other sub-task names it depends on (empty array for parallel tasks)

    Available roles (assign the most appropriate for each sub-task):
      "lead"     — orchestrator/synthesizer, merges results, makes ship decisions
      "backend"  — server-side code: APIs, handlers, services, business logic
      "frontend" — client-side code: components, pages, state, styling
      "data"     — database schemas, migrations, models, queries, data integrity
      "design"   — design specs, tokens, accessibility audits, visual consistency
      "infra"    — Dockerfiles, CI/CD, deployment, build systems, monitoring
      "qa"       — tests (unit/integration/e2e), test infra, security audit
      "red_team" — adversarial review: security vulns, edge cases, findings report
      "services" — external integrations: APIs, workers, background jobs, AI/ML

    Execution waves (sub-tasks are grouped into dependency waves):
      Wave 1 (foundation): data, qa, infra, design — no dependencies
      Wave 2 (logic):      backend, services — depends on Wave 1
      Wave 3 (presentation): frontend — depends on Wave 2
      Wave 4 (review):     red_team — depends on all prior waves
      Wave 5 (synthesis):  lead — depends on everything

    JSON format:
    {"complexity":"simple","reasoning":"This is a straightforward task"}
    OR
    {"complexity":"complex","reasoning":"This task requires...","sub_tasks":[{"name":"schema_design","description":"...","role":"data","tools_needed":["file_read"],"depends_on":[]},{"name":"api_handlers","description":"...","role":"backend","tools_needed":["file_read","file_write"],"depends_on":["schema_design"]}]}
    """

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.2, max_tokens: 1500) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        parse_complexity_response(content)

      {:ok, _} ->
        Logger.warning("[Orchestrator] Empty LLM response for complexity analysis")
        :simple

      {:error, reason} ->
        Logger.error(
          "[Orchestrator] LLM call failed during complexity analysis: #{inspect(reason)}"
        )

        :simple
    end
  end

  defp parse_complexity_response(content) do
    cleaned =
      content
      |> String.trim()
      |> OptimalSystemAgent.Utils.Text.strip_markdown_fences()
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"complexity" => "simple"}} ->
        :simple

      {:ok, %{"complexity" => "complex", "sub_tasks" => sub_tasks}} when is_list(sub_tasks) ->
        parsed =
          Enum.map(sub_tasks, fn st ->
            %SubTask{
              name: st["name"] || "unnamed",
              description: st["description"] || "",
              role: parse_role(st["role"]),
              tools_needed: st["tools_needed"] || [],
              depends_on: st["depends_on"] || []
            }
          end)

        {:complex, parsed}

      {:ok, _} ->
        Logger.warning("[Orchestrator] Unexpected complexity response format")
        :simple

      {:error, reason} ->
        Logger.warning("[Orchestrator] Failed to parse complexity JSON: #{inspect(reason)}")
        :simple
    end
  end

  # Agent-Dispatch 9-role system + legacy aliases
  defp parse_role("lead"), do: :lead
  defp parse_role("backend"), do: :backend
  defp parse_role("frontend"), do: :frontend
  defp parse_role("data"), do: :data
  defp parse_role("design"), do: :design
  defp parse_role("infra"), do: :infra
  defp parse_role("qa"), do: :qa
  defp parse_role("red_team"), do: :red_team
  defp parse_role("red-team"), do: :red_team
  defp parse_role("services"), do: :services
  # Legacy aliases
  defp parse_role("researcher"), do: :data
  defp parse_role("builder"), do: :backend
  defp parse_role("tester"), do: :qa
  defp parse_role("reviewer"), do: :red_team
  defp parse_role("writer"), do: :lead
  defp parse_role(_), do: :backend

  # ── Task Decomposition ──────────────────────────────────────────────

  defp decompose_task(message) do
    try do
      case analyze_complexity(message) do
        :simple ->
          # Create a single "do everything" sub-task
          {:ok,
           [
             %SubTask{
               name: "execute",
               description: message,
               role: :builder,
               tools_needed: ["file_read", "file_write", "shell_execute"],
               depends_on: []
             }
           ]}

        {:complex, sub_tasks} ->
          {:ok, sub_tasks}
      end
    rescue
      e ->
        {:error, "Task decomposition failed: #{Exception.message(e)}"}
    end
  end

  defp build_execution_waves(sub_tasks) do
    # Topological sort: group tasks by dependency level
    # Wave 0: no dependencies
    # Wave 1: depends only on wave 0 tasks
    # etc.
    resolved = MapSet.new()
    remaining = sub_tasks
    waves = []

    build_waves(remaining, resolved, waves)
  end

  defp build_waves([], _resolved, waves), do: Enum.reverse(waves)

  defp build_waves(remaining, resolved, waves) do
    # Find all tasks whose dependencies are satisfied
    {ready, not_ready} =
      Enum.split_with(remaining, fn st ->
        Enum.all?(st.depends_on, fn dep -> MapSet.member?(resolved, dep) end)
      end)

    if ready == [] and not_ready != [] do
      # Circular dependency or unresolvable — force everything into one wave
      Logger.warning(
        "[Orchestrator] Unresolvable dependencies detected, forcing parallel execution"
      )

      Enum.reverse([not_ready | waves])
    else
      new_resolved =
        Enum.reduce(ready, resolved, fn st, acc -> MapSet.put(acc, st.name) end)

      build_waves(not_ready, new_resolved, [ready | waves])
    end
  end

  defp build_dependency_context([], _results), do: nil

  defp build_dependency_context(depends_on, results) do
    context_parts =
      Enum.map(depends_on, fn dep_name ->
        case Map.get(results, dep_name) do
          nil -> nil
          result -> "## Results from #{dep_name}:\n#{result}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    if context_parts == [] do
      nil
    else
      Enum.join(context_parts, "\n\n---\n\n")
    end
  end

  # ── Non-blocking execution helpers ──────────────────────────────────

  # Find which task owns a given Task.async ref
  defp find_task_by_ref(ref, state) do
    Enum.find_value(state.tasks, fn {task_id, task_state} ->
      case Map.get(task_state.wave_refs, ref) do
        {agent_name, agent_id, subtask_id} ->
          {task_id, agent_name, agent_id, subtask_id}

        nil ->
          nil
      end
    end)
  end

  # Record an agent's result: update agent state, wave_refs, results map, TaskQueue
  defp record_agent_result(state, task_id, agent_name, agent_id, subtask_id, result_text, raw_result) do
    task_state = Map.get(state.tasks, task_id)

    # Update agent status
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
      if updated_agent, do: Map.put(task_state.agents, agent_id, updated_agent), else: task_state.agents

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
      agent_id: agent_id,
      agent_name: agent_name,
      status: status
    })

    %{state | tasks: Map.put(state.tasks, task_id, task_state)}
  end

  # ── Sub-Agent Spawning ──────────────────────────────────────────────

  defp spawn_agent(sub_task, task_id, session_id, cached_tools) do
    agent_id = generate_id("agent")

    # Build specialized system prompt for this agent's role
    system_prompt = build_agent_prompt(sub_task)

    # Determine tier for this agent (from Roster match or role default)
    agent_tier = resolve_agent_tier(sub_task)
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    tier_opts = %{
      model: Tier.model_for(agent_tier, provider),
      temperature: Tier.temperature(agent_tier),
      max_iterations: Tier.max_iterations(agent_tier),
      max_response_tokens: Tier.max_response_tokens(agent_tier),
      tier: agent_tier
    }

    agent_state = %AgentState{
      id: agent_id,
      task_id: task_id,
      name: sub_task.name,
      role: sub_task.role,
      status: :running,
      tool_uses: 0,
      tokens_used: 0,
      started_at: DateTime.utc_now()
    }

    Bus.emit(:system_event, %{
      event: :orchestrator_agent_started,
      task_id: task_id,
      agent_id: agent_id,
      agent_name: sub_task.name,
      role: sub_task.role,
      tier: agent_tier,
      model: tier_opts.model
    })

    # Run the agent asynchronously
    orchestrator_pid = self()

    task_ref =
      Task.async(fn ->
        run_agent_loop(
          agent_id,
          task_id,
          system_prompt,
          sub_task,
          session_id,
          orchestrator_pid,
          cached_tools,
          tier_opts
        )
      end)

    {agent_id, agent_state, task_ref}
  end

  # Resolve which tier an agent should run at based on Roster or role defaults.
  defp resolve_agent_tier(sub_task) do
    case Roster.find_by_trigger(sub_task.description) do
      %{tier: tier} ->
        tier

      nil ->
        # Map roles to default tiers
        case sub_task.role do
          :lead -> :elite
          :red_team -> :specialist
          _ -> :specialist
        end
    end
  end

  # ── Agent Loop (runs inside Task.async) ─────────────────────────────

  defp run_agent_loop(
         agent_id,
         task_id,
         system_prompt,
         sub_task,
         _session_id,
         orchestrator_pid,
         cached_tools,
         tier_opts
       ) do
    # Build the conversation for this sub-agent
    user_message =
      if sub_task.context do
        """
        ## Task
        #{sub_task.description}

        ## Context from Previous Agents
        #{sub_task.context}
        """
      else
        sub_task.description
      end

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_message}
    ]

    # Use cached tools or read from persistent_term (lock-free).
    # NEVER call Tools.list_tools() here — it goes through the GenServer
    # which is blocked by the Tools.Registry.execute call that started us.
    tools =
      if cached_tools != [] do
        cached_tools
      else
        Tools.list_tools_direct()
      end

    # Filter tools to only what this agent needs (if specified)
    tools =
      if sub_task.tools_needed != [] do
        Enum.filter(tools, fn tool ->
          tool.name in sub_task.tools_needed
        end)
      else
        tools
      end

    # Run the agent's ReAct loop with tier-aware model and temperature
    max_iters = tier_opts.max_iterations

    run_sub_agent_iterations(
      agent_id,
      task_id,
      messages,
      tools,
      orchestrator_pid,
      0,
      0,
      0,
      tier_opts,
      max_iters
    )
  end

  defp run_sub_agent_iterations(
         agent_id,
         task_id,
         messages,
         _tools,
         orchestrator_pid,
         iteration,
         tool_uses,
         tokens_used,
         _tier_opts,
         max_iters
       )
       when iteration >= max_iters do
    Logger.warning("[Orchestrator] Sub-agent #{agent_id} hit max iterations (#{max_iters})")

    # Report final progress
    GenServer.cast(
      orchestrator_pid,
      {:agent_progress, task_id, agent_id,
       %{
         tool_uses: tool_uses,
         tokens_used: tokens_used,
         current_action: "Completed (max iterations)"
       }}
    )

    # Extract the last assistant message as the result
    last_assistant =
      messages
      |> Enum.reverse()
      |> Enum.find(fn msg -> msg.role == "assistant" end)

    {:ok,
     (last_assistant && last_assistant.content) ||
       "Agent reached iteration limit without producing a result."}
  end

  defp run_sub_agent_iterations(
         agent_id,
         task_id,
         messages,
         tools,
         orchestrator_pid,
         iteration,
         tool_uses,
         tokens_used,
         tier_opts,
         max_iters
       ) do
    # Emit progress update
    GenServer.cast(
      orchestrator_pid,
      {:agent_progress, task_id, agent_id,
       %{
         tool_uses: tool_uses,
         tokens_used: tokens_used,
         current_action: "Thinking... (iteration #{iteration + 1}/#{max_iters})"
       }}
    )

    # Tier-aware LLM options: model + temperature from the agent's tier
    llm_opts = [
      tools: tools,
      temperature: tier_opts.temperature,
      model: tier_opts.model,
      max_tokens: tier_opts.max_response_tokens
    ]

    try do
      case Providers.chat(messages, llm_opts) do
        {:ok, %{content: content, tool_calls: []}} ->
          # No tool calls — final response
          estimated_tokens = tokens_used + estimate_tokens(content)

          GenServer.cast(
            orchestrator_pid,
            {:agent_progress, task_id, agent_id,
             %{
               tool_uses: tool_uses,
               tokens_used: estimated_tokens,
               current_action: "Done"
             }}
          )

          {:ok, content}

        {:ok, %{content: content, tool_calls: tool_calls}}
        when is_list(tool_calls) and tool_calls != [] ->
          # Execute tool calls
          new_tool_uses = tool_uses + length(tool_calls)
          estimated_tokens = tokens_used + estimate_tokens(content)

          messages = messages ++ [%{role: "assistant", content: content, tool_calls: tool_calls}]

          # Execute each tool and collect results
          {messages, new_tool_uses_final, estimated_tokens_final} =
            Enum.reduce(tool_calls, {messages, new_tool_uses, estimated_tokens}, fn tool_call,
                                                                                    {msgs, tu, et} ->
              # Report what we're doing
              GenServer.cast(
                orchestrator_pid,
                {:agent_progress, task_id, agent_id,
                 %{
                   tool_uses: tu,
                   tokens_used: et,
                   current_action: "Running #{tool_call.name}"
                 }}
              )

              # Use execute_direct to bypass GenServer — Tools.Registry is blocked
              # by the parent execute("orchestrate") call that spawned us.
              result_str =
                case Tools.execute_direct(tool_call.name, tool_call.arguments) do
                  {:ok, output} -> output
                  {:error, reason} -> "Error: #{reason}"
                end

              tool_msg = %{role: "tool", tool_call_id: tool_call.id, content: result_str}
              {msgs ++ [tool_msg], tu, et + estimate_tokens(result_str)}
            end)

          # Re-prompt with same tier opts
          run_sub_agent_iterations(
            agent_id,
            task_id,
            messages,
            tools,
            orchestrator_pid,
            iteration + 1,
            new_tool_uses_final,
            estimated_tokens_final,
            tier_opts,
            max_iters
          )

        {:ok, %{content: content}} when is_binary(content) and content != "" ->
          # Response with content but no tool_calls key
          {:ok, content}

        {:error, reason} ->
          Logger.error("[Orchestrator] Sub-agent #{agent_id} LLM call failed: #{inspect(reason)}")
          {:error, "LLM call failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("[Orchestrator] Sub-agent #{agent_id} crashed: #{Exception.message(e)}")
        {:error, "Agent crashed: #{Exception.message(e)}"}
    end
  end

  # ── Agent Role Prompts ──────────────────────────────────────────────

  defp build_agent_prompt(sub_task) do
    # First try the Roster for a named agent match, then fall back to role_prompts
    role_prompt =
      case Roster.find_by_trigger(sub_task.description) do
        %{prompt: prompt} -> prompt
        nil -> Roster.role_prompt(sub_task.role)
      end

    # Get tier-appropriate settings
    agent_tier =
      case Roster.find_by_trigger(sub_task.description) do
        %{tier: tier} -> tier
        nil -> :specialist
      end

    max_iters = Tier.max_iterations(agent_tier)

    """
    #{role_prompt}

    ## Your Specific Task
    #{sub_task.description}

    ## Available Tools
    #{Enum.join(sub_task.tools_needed || [], ", ")}

    ## Execution Parameters
    - Tier: #{agent_tier}
    - Max iterations: #{max_iters}
    - Token budget: #{Tier.total_budget(agent_tier)}

    ## Rules
    - Focus ONLY on your assigned task
    - Be thorough but efficient
    - Report your results clearly when done
    - If you encounter a blocker, state it clearly and do what you can
    - Match existing codebase patterns and conventions
    """
  end

  # ── Result Synthesis ────────────────────────────────────────────────

  defp synthesize_results(task_id, results, original_message) do
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
            # Fallback: join all results
            Logger.warning(
              "[Orchestrator] Synthesis LLM call failed -- falling back to joined results"
            )

            Enum.map_join(results, "\n\n---\n\n", fn {name, result} ->
              "## #{name}\n#{result}"
            end)
        end
      rescue
        e ->
          Logger.error("[Orchestrator] Synthesis failed: #{Exception.message(e)}")

          Enum.map_join(results, "\n\n---\n\n", fn {name, result} ->
            "## #{name}\n#{result}"
          end)
      end
    end
  end

  # ── Simple Execution (single-agent fallback) ────────────────────────

  defp run_simple(message, _session_id) do
    messages = [%{role: "user", content: message}]

    try do
      case Providers.chat(messages, temperature: 0.5, max_tokens: 2000) do
        {:ok, %{content: content}} when is_binary(content) -> content
        _ -> "Failed to process the task."
      end
    rescue
      _ -> "Failed to process the task."
    end
  end

  # ── Dynamic Skill Creation ──────────────────────────────────────────

  defp do_create_skill(name, description, instructions, tools) do
    skill_dir = Path.expand("~/.osa/skills/#{name}")

    try do
      File.mkdir_p!(skill_dir)

      tools_yaml =
        case tools do
          [] -> ""
          list -> Enum.map_join(list, "\n", fn t -> "  - #{t}" end)
        end

      skill_content = """
      ---
      name: #{name}
      description: #{description}
      tools:
      #{tools_yaml}
      ---

      ## Instructions

      #{instructions}
      """

      skill_path = Path.join(skill_dir, "SKILL.md")
      File.write!(skill_path, skill_content)

      Logger.info("[Orchestrator] Created new skill file: #{skill_path}")

      Bus.emit(:system_event, %{
        event: :orchestrator_skill_created,
        name: name,
        description: description,
        path: skill_path
      })

      {:ok, name}
    rescue
      e ->
        Logger.error("[Orchestrator] Failed to create skill #{name}: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  # ── Skill Discovery ───────────────────────────────────────────────

  defp do_find_matching_skills(task_description) do
    search_results = Tools.search(task_description)

    if search_results == [] do
      :no_matches
    else
      matches =
        Enum.map(search_results, fn {name, description, relevance} ->
          %{name: name, description: description, relevance: relevance}
        end)

      {:matches, matches}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp generate_id(prefix),
    do: OptimalSystemAgent.Utils.ID.generate(prefix)

  defp estimate_tokens(nil), do: 0

  defp estimate_tokens(text) when is_binary(text) do
    # Rough estimate: ~4 chars per token
    div(String.length(text), 4)
  end

  defp estimate_tokens(_), do: 0
end
