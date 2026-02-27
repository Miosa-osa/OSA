defmodule OptimalSystemAgent.Swarm.PACT do
  @moduledoc """
  PACT Framework — Planning, Action, Coordination, Testing.

  Implements a structured 4-phase workflow for complex task execution:

  1. **Planning**      — Single agent analyzes the task, decomposes into subtasks
  2. **Action**        — Parallel agents execute subtasks concurrently
  3. **Coordination**  — Synthesize results, resolve conflicts between outputs
  4. **Testing**       — Validate outputs, run quality checks

  Each phase transition passes through a configurable quality gate.
  If a phase fails, the framework supports rollback to a previous phase
  or full abort with collected results.

  ## Usage

      opts = [
        quality_threshold: 0.7,
        timeout_ms: 300_000,
        max_action_agents: 5
      ]
      {:ok, result} = OptimalSystemAgent.Swarm.PACT.execute_pact("Build a REST API", opts)

  ## Events

  Emits `system_event` on the Bus at each phase transition:
    - `%{event: :pact_phase_started, phase: :planning, ...}`
    - `%{event: :pact_phase_completed, phase: :planning, ...}`
    - `%{event: :pact_gate_passed, phase: :planning, ...}`
    - `%{event: :pact_gate_failed, phase: :action, ...}`
    - `%{event: :pact_workflow_completed, ...}`
    - `%{event: :pact_workflow_failed, ...}`
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Swarm.{Mailbox, Worker}

  # ── Types ──────────────────────────────────────────────────────────

  @type phase :: :planning | :action | :coordination | :testing

  @type quality_gate :: %{
          name: String.t(),
          criteria: [String.t()],
          passed: boolean(),
          score: float(),
          timestamp: DateTime.t() | nil
        }

  @type phase_result :: %{
          phase: phase(),
          status: :ok | :failed | :skipped,
          output: term(),
          gate: quality_gate(),
          duration_ms: non_neg_integer()
        }

  @type pact_result :: %{
          status: :completed | :failed | :rolled_back,
          task: String.t(),
          phases: [phase_result()],
          final_output: String.t() | nil,
          total_duration_ms: non_neg_integer()
        }

  # ── Default Options ────────────────────────────────────────────────

  @default_opts [
    quality_threshold: 0.7,
    timeout_ms: 300_000,
    max_action_agents: 5,
    rollback_on_failure: true,
    planning_role: :planner,
    coordination_role: :lead,
    testing_role: :tester
  ]

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Execute a full PACT workflow for a given task.

  Runs through Planning -> Action -> Coordination -> Testing with
  quality gates between each phase. Returns `{:ok, pact_result}` on
  success or `{:error, pact_result}` if any phase fails fatally.

  ## Options

    * `:quality_threshold` — minimum score (0.0-1.0) to pass a gate (default: 0.7)
    * `:timeout_ms` — per-phase timeout in milliseconds (default: 300_000)
    * `:max_action_agents` — maximum parallel agents in the Action phase (default: 5)
    * `:rollback_on_failure` — if true, attempt rollback on phase failure (default: true)
    * `:planning_role` — worker role for the Planning phase (default: :planner)
    * `:coordination_role` — worker role for Coordination phase (default: :lead)
    * `:testing_role` — worker role for Testing phase (default: :tester)
  """
  @spec execute_pact(String.t(), keyword()) :: {:ok, pact_result()} | {:error, pact_result()}
  def execute_pact(task, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    swarm_id = generate_id()
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[PACT] Starting workflow for: #{String.slice(task, 0, 100)}")

    Bus.emit(:system_event, %{
      event: :pact_workflow_started,
      swarm_id: swarm_id,
      task: String.slice(task, 0, 200)
    })

    Mailbox.create(swarm_id)

    result =
      with {:ok, planning} <- run_phase(:planning, task, swarm_id, opts, []),
           :ok <- check_gate(:planning, planning, opts),
           {:ok, action} <- run_phase(:action, task, swarm_id, opts, [planning]),
           :ok <- check_gate(:action, action, opts),
           {:ok, coordination} <-
             run_phase(:coordination, task, swarm_id, opts, [planning, action]),
           :ok <- check_gate(:coordination, coordination, opts),
           {:ok, testing} <-
             run_phase(:testing, task, swarm_id, opts, [planning, action, coordination]),
           :ok <- check_gate(:testing, testing, opts) do
        phases = [planning, action, coordination, testing]
        total_ms = System.monotonic_time(:millisecond) - start_time

        pact_result = %{
          status: :completed,
          task: task,
          phases: phases,
          final_output: testing.output,
          total_duration_ms: total_ms
        }

        Bus.emit(:system_event, %{
          event: :pact_workflow_completed,
          swarm_id: swarm_id,
          duration_ms: total_ms,
          phases_completed: 4
        })

        Logger.info("[PACT] Workflow completed in #{total_ms}ms")
        Mailbox.clear(swarm_id)
        {:ok, pact_result}
      else
        {:gate_failed, phase, phase_result, completed_phases} ->
          total_ms = System.monotonic_time(:millisecond) - start_time

          if opts[:rollback_on_failure] do
            Logger.warning("[PACT] Gate failed at #{phase}, rolling back")
            rollback(completed_phases, swarm_id)
          end

          pact_result = %{
            status: if(opts[:rollback_on_failure], do: :rolled_back, else: :failed),
            task: task,
            phases: completed_phases ++ [phase_result],
            final_output: nil,
            total_duration_ms: total_ms
          }

          Bus.emit(:system_event, %{
            event: :pact_workflow_failed,
            swarm_id: swarm_id,
            failed_phase: phase,
            duration_ms: total_ms
          })

          Mailbox.clear(swarm_id)
          {:error, pact_result}

        {:error, phase, reason, completed_phases} ->
          total_ms = System.monotonic_time(:millisecond) - start_time

          failed_result = %{
            phase: phase,
            status: :failed,
            output: reason,
            gate: %{
              name: "#{phase}",
              criteria: [],
              passed: false,
              score: 0.0,
              timestamp: DateTime.utc_now()
            },
            duration_ms: 0
          }

          pact_result = %{
            status: :failed,
            task: task,
            phases: completed_phases ++ [failed_result],
            final_output: nil,
            total_duration_ms: total_ms
          }

          Bus.emit(:system_event, %{
            event: :pact_workflow_failed,
            swarm_id: swarm_id,
            failed_phase: phase,
            reason: inspect(reason),
            duration_ms: total_ms
          })

          Mailbox.clear(swarm_id)
          {:error, pact_result}
      end

    result
  end

  # ── Phase Execution ────────────────────────────────────────────────

  defp run_phase(:planning, task, swarm_id, opts, _completed) do
    phase_start = System.monotonic_time(:millisecond)
    Bus.emit(:system_event, %{event: :pact_phase_started, phase: :planning, swarm_id: swarm_id})

    prompt = """
    You are the PLANNING agent in a PACT workflow.

    Analyze the following task and break it into discrete, actionable subtasks.
    For each subtask, specify:
    - A short title
    - A clear description of what needs to be done
    - The role best suited to execute it (researcher, coder, reviewer, architect, tester, writer)
    - Complexity (1-10)
    - Dependencies on other subtasks (by title)

    Format your response as a structured plan that other agents can execute in parallel.

    ## Task
    #{task}
    """

    case dispatch_single_agent(swarm_id, opts[:planning_role], prompt, opts[:timeout_ms]) do
      {:ok, output} ->
        duration = System.monotonic_time(:millisecond) - phase_start

        Bus.emit(:system_event, %{
          event: :pact_phase_completed,
          phase: :planning,
          swarm_id: swarm_id,
          duration_ms: duration
        })

        {:ok,
         %{
           phase: :planning,
           status: :ok,
           output: output,
           gate: nil,
           duration_ms: duration
         }}

      {:error, reason} ->
        {:error, :planning, reason, []}
    end
  end

  defp run_phase(:action, task, swarm_id, opts, completed) do
    phase_start = System.monotonic_time(:millisecond)
    Bus.emit(:system_event, %{event: :pact_phase_started, phase: :action, swarm_id: swarm_id})

    planning_output = get_phase_output(completed, :planning)

    # Parse subtasks from planning output and dispatch parallel agents
    subtasks = extract_subtasks(planning_output, task, opts[:max_action_agents])

    results =
      subtasks
      |> Task.async_stream(
        fn {role, subtask_prompt} ->
          case dispatch_single_agent(swarm_id, role, subtask_prompt, opts[:timeout_ms]) do
            {:ok, result} -> %{role: role, result: result, status: :ok}
            {:error, reason} -> %{role: role, result: inspect(reason), status: :failed}
          end
        end,
        timeout: opts[:timeout_ms],
        on_timeout: :kill_task,
        ordered: true,
        max_concurrency: opts[:max_action_agents]
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          %{role: :unknown, result: "Task exited: #{inspect(reason)}", status: :failed}
      end)

    duration = System.monotonic_time(:millisecond) - phase_start
    successful = Enum.count(results, &(&1.status == :ok))

    Bus.emit(:system_event, %{
      event: :pact_phase_completed,
      phase: :action,
      swarm_id: swarm_id,
      agents_total: length(results),
      agents_succeeded: successful,
      duration_ms: duration
    })

    combined_output =
      results
      |> Enum.map(fn r -> "## Agent (#{r.role}) [#{r.status}]\n#{r.result}" end)
      |> Enum.join("\n\n---\n\n")

    {:ok,
     %{
       phase: :action,
       status: if(successful > 0, do: :ok, else: :failed),
       output: combined_output,
       gate: nil,
       duration_ms: duration
     }}
  end

  defp run_phase(:coordination, task, swarm_id, opts, completed) do
    phase_start = System.monotonic_time(:millisecond)

    Bus.emit(:system_event, %{
      event: :pact_phase_started,
      phase: :coordination,
      swarm_id: swarm_id
    })

    action_output = get_phase_output(completed, :action)

    prompt = """
    You are the COORDINATION agent in a PACT workflow.

    Multiple action agents have completed their work. Your job is to:
    1. Review all agent outputs for consistency
    2. Resolve any conflicts between agent outputs
    3. Synthesize the results into a cohesive whole
    4. Identify any gaps or missing pieces
    5. Prepare context for the testing phase

    ## Original Task
    #{task}

    ## Agent Outputs
    #{action_output}

    Produce a consolidated result that merges the best elements from all agents.
    Note any conflicts resolved and decisions made.
    """

    case dispatch_single_agent(swarm_id, opts[:coordination_role], prompt, opts[:timeout_ms]) do
      {:ok, output} ->
        duration = System.monotonic_time(:millisecond) - phase_start

        Bus.emit(:system_event, %{
          event: :pact_phase_completed,
          phase: :coordination,
          swarm_id: swarm_id,
          duration_ms: duration
        })

        {:ok,
         %{
           phase: :coordination,
           status: :ok,
           output: output,
           gate: nil,
           duration_ms: duration
         }}

      {:error, reason} ->
        {:error, :coordination, reason, completed}
    end
  end

  defp run_phase(:testing, task, swarm_id, opts, completed) do
    phase_start = System.monotonic_time(:millisecond)
    Bus.emit(:system_event, %{event: :pact_phase_started, phase: :testing, swarm_id: swarm_id})

    coordination_output = get_phase_output(completed, :coordination)

    prompt = """
    You are the TESTING agent in a PACT workflow.

    Validate the coordinated output against the original task requirements:
    1. Does the output address all aspects of the original task?
    2. Are there logical errors or inconsistencies?
    3. Is the quality sufficient for production use?
    4. What is missing or could be improved?

    Rate the overall quality on a scale of 0.0 to 1.0.
    Begin your response with the score in this exact format: QUALITY_SCORE: 0.85

    ## Original Task
    #{task}

    ## Coordinated Output
    #{coordination_output}

    Provide a detailed quality report.
    """

    case dispatch_single_agent(swarm_id, opts[:testing_role], prompt, opts[:timeout_ms]) do
      {:ok, output} ->
        duration = System.monotonic_time(:millisecond) - phase_start

        Bus.emit(:system_event, %{
          event: :pact_phase_completed,
          phase: :testing,
          swarm_id: swarm_id,
          duration_ms: duration
        })

        {:ok,
         %{
           phase: :testing,
           status: :ok,
           output: output,
           gate: nil,
           duration_ms: duration
         }}

      {:error, reason} ->
        {:error, :testing, reason, completed}
    end
  end

  # ── Quality Gates ──────────────────────────────────────────────────

  defp check_gate(phase, phase_result, opts) do
    threshold = opts[:quality_threshold]
    score = compute_gate_score(phase, phase_result)

    gate = %{
      name: "#{phase}_gate",
      criteria: gate_criteria(phase),
      passed: score >= threshold,
      score: score,
      timestamp: DateTime.utc_now()
    }

    updated_result = %{phase_result | gate: gate}

    if gate.passed do
      Bus.emit(:system_event, %{
        event: :pact_gate_passed,
        phase: phase,
        score: score,
        threshold: threshold
      })

      Logger.info("[PACT] Gate passed: #{phase} (score: #{score}, threshold: #{threshold})")
      :ok
    else
      Bus.emit(:system_event, %{
        event: :pact_gate_failed,
        phase: phase,
        score: score,
        threshold: threshold
      })

      Logger.warning("[PACT] Gate FAILED: #{phase} (score: #{score}, threshold: #{threshold})")
      {:gate_failed, phase, updated_result, []}
    end
  end

  defp compute_gate_score(phase, phase_result) do
    case phase_result.status do
      :failed -> 0.0
      :ok -> score_phase_output(phase, phase_result.output)
    end
  end

  # Score based on output characteristics per phase
  defp score_phase_output(:planning, output) when is_binary(output) do
    base = if String.length(output) > 50, do: 0.6, else: 0.3

    # Bonus for structured content
    has_subtasks = String.contains?(output, ["subtask", "task", "step", "1.", "- "])

    has_roles =
      String.contains?(output, ["researcher", "coder", "reviewer", "architect", "tester"])

    base +
      if(has_subtasks, do: 0.2, else: 0.0) +
      if has_roles, do: 0.2, else: 0.0
  end

  defp score_phase_output(:action, output) when is_binary(output) do
    # Score based on how many agents succeeded
    total = length(Regex.scan(~r/## Agent/, output))
    succeeded = length(Regex.scan(~r/\[ok\]/, output))

    if total > 0 do
      0.5 + 0.5 * (succeeded / total)
    else
      0.3
    end
  end

  defp score_phase_output(:coordination, output) when is_binary(output) do
    if String.length(output) > 100, do: 0.8, else: 0.5
  end

  defp score_phase_output(:testing, output) when is_binary(output) do
    # Try to extract explicit quality score from the testing agent
    case Regex.run(~r/QUALITY_SCORE:\s*([\d.]+)/, output) do
      [_, score_str] ->
        case Float.parse(score_str) do
          {score, _} -> min(max(score, 0.0), 1.0)
          :error -> 0.7
        end

      nil ->
        # Fallback heuristic
        if String.length(output) > 100, do: 0.75, else: 0.5
    end
  end

  defp score_phase_output(_phase, _output), do: 0.5

  defp gate_criteria(:planning), do: ["Output received", "Subtasks identified", "Roles assigned"]
  defp gate_criteria(:action), do: ["At least one agent succeeded", "Outputs non-empty"]
  defp gate_criteria(:coordination), do: ["Conflicts resolved", "Output synthesized"]
  defp gate_criteria(:testing), do: ["Quality score above threshold", "No critical issues"]

  # ── Agent Dispatch ─────────────────────────────────────────────────

  defp dispatch_single_agent(swarm_id, role, prompt, timeout_ms) do
    worker_id = generate_id()

    init_opts = %{id: worker_id, swarm_id: swarm_id, role: role}

    case DynamicSupervisor.start_child(
           OptimalSystemAgent.Swarm.AgentPool,
           {Worker, init_opts}
         ) do
      {:ok, pid} ->
        try do
          Worker.assign(pid, prompt, timeout_ms)
        catch
          :exit, {:timeout, _} ->
            Logger.warning("[PACT] Agent #{role} timed out after #{timeout_ms}ms")
            {:error, :timeout}

          :exit, reason ->
            Logger.warning("[PACT] Agent #{role} exited: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[PACT] Failed to start worker for role #{role}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Subtask Extraction ─────────────────────────────────────────────

  # Extract subtasks from the planning output.
  # Tries to parse structured output; falls back to splitting the task.
  defp extract_subtasks(planning_output, original_task, max_agents)
       when is_binary(planning_output) do
    # Try to identify roles mentioned in the planning output
    role_map = %{
      "researcher" => :researcher,
      "research" => :researcher,
      "coder" => :coder,
      "code" => :coder,
      "implement" => :coder,
      "reviewer" => :reviewer,
      "review" => :reviewer,
      "architect" => :architect,
      "architecture" => :architect,
      "tester" => :tester,
      "test" => :tester,
      "writer" => :writer,
      "write" => :writer,
      "document" => :writer,
      "backend" => :backend,
      "frontend" => :frontend,
      "data" => :data,
      "database" => :data,
      "infra" => :infra,
      "infrastructure" => :infra,
      "devops" => :infra,
      "security" => :red_team,
      "qa" => :qa
    }

    # Split planning output into sections that look like subtasks
    sections =
      planning_output
      |> String.split(~r/\n(?=(?:\d+\.|[#]{1,3}\s|-\s+\*{0,2}(?:subtask|task|step)))/i)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.take(max_agents)

    if length(sections) >= 2 do
      Enum.map(sections, fn section ->
        # Try to detect role from section content
        role =
          Enum.find_value(role_map, :coder, fn {keyword, role} ->
            if String.contains?(String.downcase(section), keyword), do: role
          end)

        prompt = """
        ## Context from Planning Phase
        #{planning_output}

        ## Your Specific Subtask
        #{section}

        Complete this subtask thoroughly. Be specific and actionable.
        """

        {role, prompt}
      end)
    else
      # Fallback: create a research + implementation pair
      [
        {:researcher,
         """
         ## Task to Research
         #{original_task}

         ## Planning Context
         #{planning_output}

         Research the best approaches, patterns, and considerations for this task.
         """},
        {:coder,
         """
         ## Task to Implement
         #{original_task}

         ## Planning Context
         #{planning_output}

         Implement the solution based on the plan above.
         """}
      ]
      |> Enum.take(max_agents)
    end
  end

  defp extract_subtasks(_planning_output, original_task, _max_agents) do
    [{:coder, "Complete this task:\n#{original_task}"}]
  end

  # ── Rollback ───────────────────────────────────────────────────────

  defp rollback(completed_phases, swarm_id) do
    Logger.info(
      "[PACT] Rolling back #{length(completed_phases)} completed phase(s) for swarm #{swarm_id}"
    )

    Bus.emit(:system_event, %{
      event: :pact_rollback,
      swarm_id: swarm_id,
      phases_rolled_back: Enum.map(completed_phases, & &1.phase)
    })

    # Rollback is informational — we clear the mailbox and log.
    # Actual rollback actions (reverting files, etc.) would need
    # to be implemented per-phase if the agents modify state.
    Mailbox.clear(swarm_id)
    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp get_phase_output(phases, target_phase) do
    case Enum.find(phases, &(&1.phase == target_phase)) do
      %{output: output} when is_binary(output) -> output
      _ -> "(no output from #{target_phase} phase)"
    end
  end

  defp generate_id do
    "pact_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
