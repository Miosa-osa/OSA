defmodule OptimalSystemAgent.Swarm.Patterns do
  @moduledoc """
  Predefined swarm execution patterns.

  Each pattern receives a list of `{agent_spec, pid}` tuples (from the plan)
  and executes them according to the coordination strategy. All patterns return
  a list of result maps that the Orchestrator synthesises into a final output.

  ## Patterns

  - `parallel/3`     — All agents work independently; results merged by position
  - `pipeline/3`     — Agent A output flows into Agent B's task context, then C
  - `debate/3`       — All agents propose; last agent (critic) evaluates all proposals
  - `review_loop/4`  — Coder works, reviewer checks, iterate up to max_iterations

  ## Result shape

  Each pattern returns `[%{role, task, result, status}]` — a list of per-agent
  results ordered by the agents list. The Orchestrator uses this to build the
  synthesis prompt.
  """
  require Logger

  alias OptimalSystemAgent.Swarm.Worker

  # ── Parallel ─────────────────────────────────────────────────────────

  @doc """
  All agents work independently on their assigned subtask.
  Uses Task.async_stream for true parallelism with bounded concurrency.
  Results are collected in agent order.
  """
  def parallel(workers, agent_specs, _swarm_id) do
    Logger.debug("Swarm pattern: parallel (#{length(workers)} agents)")

    workers
    |> Enum.zip(agent_specs)
    |> Task.async_stream(
      fn {{_spec, pid}, agent} ->
        case Worker.assign(pid, agent.task) do
          {:ok, result} ->
            %{role: agent.role, task: agent.task, result: result, status: :done}

          {:error, reason} ->
            Logger.warning("Parallel worker #{agent.role} failed: #{inspect(reason)}")
            %{role: agent.role, task: agent.task, result: nil, status: :failed}
        end
      end,
      timeout: 300_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} ->
        Logger.error("Parallel agent task exited: #{inspect(reason)}")
        %{role: :unknown, task: "unknown", result: nil, status: :failed}
    end)
  end

  # ── Pipeline ─────────────────────────────────────────────────────────

  @doc """
  Agents execute sequentially. Each agent receives the previous agent's output
  prepended to its task so it can build on prior work.
  Agent A -> Agent B (with A's result) -> Agent C (with B's result) -> ...
  """
  def pipeline(workers, agent_specs, _swarm_id) do
    Logger.debug("Swarm pattern: pipeline (#{length(workers)} agents)")

    pairs = Enum.zip(workers, agent_specs)

    {results, _acc} =
      Enum.map_reduce(pairs, nil, fn {{_spec, pid}, agent}, prev_result ->
        task_with_context =
          if prev_result do
            """
            ## Previous agent output (use this as your starting point):
            #{prev_result}

            ## Your task:
            #{agent.task}
            """
          else
            agent.task
          end

        result =
          case Worker.assign(pid, task_with_context) do
            {:ok, text} ->
              %{role: agent.role, task: agent.task, result: text, status: :done}

            {:error, reason} ->
              Logger.warning("Pipeline agent #{agent.role} failed: #{inspect(reason)}")
              # Propagate nil so the next agent gets no context from this failed step
              %{role: agent.role, task: agent.task, result: nil, status: :failed}
          end

        {result, result.result}
      end)

    results
  end

  # ── Debate ───────────────────────────────────────────────────────────

  @doc """
  All proposal agents work in parallel on the same task.
  The last agent in the list acts as the critic/evaluator and receives
  all proposals to produce the final synthesised answer.
  Falls back to parallel execution when fewer than 2 agents are provided.
  """
  def debate(workers, agent_specs, swarm_id) when length(workers) < 2 do
    Logger.warning("Debate pattern needs at least 2 agents, got #{length(workers)}. Running as parallel.")
    parallel(workers, agent_specs, swarm_id)
  end

  def debate(workers, agent_specs, _swarm_id) do
    Logger.debug("Swarm pattern: debate (#{length(workers)} agents)")

    # Split: first N-1 agents propose, last agent evaluates
    {proposal_pairs, [evaluator_pair]} = Enum.split(Enum.zip(workers, agent_specs), -1)
    {{_eval_spec, evaluator_pid}, evaluator_agent} = evaluator_pair

    proposal_agents = Enum.map(proposal_pairs, fn {_worker, spec} -> spec end)

    # All proposals run in parallel
    proposal_results =
      proposal_pairs
      |> Enum.zip(proposal_agents)
      |> Task.async_stream(
        fn {{_spec, pid}, agent} ->
          case Worker.assign(pid, agent.task) do
            {:ok, result} ->
              %{role: agent.role, task: agent.task, result: result, status: :done}

            {:error, reason} ->
              Logger.warning("Debate proposer #{agent.role} failed: #{inspect(reason)}")
              %{role: agent.role, task: agent.task, result: nil, status: :failed}
          end
        end,
        timeout: 300_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, r} -> r
        {:exit, _} -> %{role: :unknown, task: "unknown", result: nil, status: :failed}
      end)

    # Build evaluation prompt from all proposals
    proposals_text =
      proposal_results
      |> Enum.with_index(1)
      |> Enum.map(fn
        {%{result: nil, role: role}, i} -> "### Proposal #{i} (#{role})\n(failed - no output)"
        {%{result: text, role: role}, i} -> "### Proposal #{i} (#{role})\n#{text}"
      end)
      |> Enum.join("\n\n")

    eval_task = """
    ## Your role
    You are the evaluator in a multi-agent debate. Review the proposals below and
    produce the best possible answer by selecting, merging, and improving upon them.

    ## Original task
    #{evaluator_agent.task}

    ## Proposals from other agents

    #{proposals_text}

    ## Instructions
    Synthesise the best answer. Identify which proposal(s) are strongest, explain
    briefly why, and provide the final consolidated response.
    """

    evaluator_result =
      case Worker.assign(evaluator_pid, eval_task) do
        {:ok, text} ->
          %{role: evaluator_agent.role, task: evaluator_agent.task, result: text, status: :done}

        {:error, reason} ->
          Logger.warning("Debate evaluator failed: #{inspect(reason)}")
          %{role: evaluator_agent.role, task: evaluator_agent.task, result: nil, status: :failed}
      end

    proposal_results ++ [evaluator_result]
  end

  # ── Review Loop ───────────────────────────────────────────────────────

  @doc """
  One agent (worker) produces output; a second (reviewer) critiques it.
  Iterates up to max_iterations or until the reviewer approves.

  Approval signal: the reviewer's response starts with "APPROVED" (case-insensitive).
  Falls back to parallel execution when fewer than 2 agents are provided.
  """
  def review_loop(workers, agent_specs, swarm_id, max_iterations \\ 3)

  def review_loop(workers, agent_specs, swarm_id, _max_iterations) when length(workers) < 2 do
    Logger.warning("Review pattern needs at least 2 agents. Running as parallel.")
    parallel(workers, agent_specs, swarm_id)
  end

  def review_loop(workers, agent_specs, _swarm_id, max_iterations) do
    Logger.debug("Swarm pattern: review_loop (max_iterations=#{max_iterations})")

    [{_worker_spec, worker_pid}, {_reviewer_spec, reviewer_pid} | _] = Enum.zip(workers, agent_specs)
    [worker_agent, reviewer_agent | _] = agent_specs

    do_review_loop(
      worker_pid, worker_agent,
      reviewer_pid, reviewer_agent,
      max_iterations, 1,
      nil, []
    )
  end

  # ── Review Loop — Private Recursion ──────────────────────────────────

  defp do_review_loop(_worker_pid, worker_agent, _reviewer_pid, reviewer_agent, max, iter, _prev_review, acc)
       when iter > max do
    Logger.info("Review loop exhausted #{max} iterations without approval")

    last_worker = Enum.find(acc, &(&1.role == worker_agent.role))

    final = %{
      role: reviewer_agent.role,
      task: reviewer_agent.task,
      result: "Max iterations reached. Final worker output:\n#{last_worker && last_worker.result}",
      status: :done
    }

    acc ++ [final]
  end

  defp do_review_loop(worker_pid, worker_agent, reviewer_pid, reviewer_agent, max, iter, prev_review, acc) do
    Logger.debug("Review loop iteration #{iter}/#{max}")

    worker_task =
      if prev_review do
        """
        ## Reviewer feedback (address this in your revision):
        #{prev_review}

        ## Your original task:
        #{worker_agent.task}

        Revise your work based on the feedback above.
        """
      else
        worker_agent.task
      end

    # Worker produces or revises output
    worker_result =
      case Worker.assign(worker_pid, worker_task) do
        {:ok, text} ->
          %{role: worker_agent.role, task: worker_agent.task, result: text, status: :done}

        {:error, reason} ->
          Logger.warning("Review loop worker failed at iter #{iter}: #{inspect(reason)}")
          %{role: worker_agent.role, task: worker_agent.task, result: nil, status: :failed}
      end

    updated_acc = acc ++ [worker_result]

    case worker_result do
      %{result: nil} ->
        # Worker failed - skip review and return what we have
        updated_acc

      %{result: worker_text} ->
        review_task = """
        ## Work to review (iteration #{iter}):
        #{worker_text}

        ## Review criteria:
        #{reviewer_agent.task}

        ## Instructions:
        Provide specific, actionable feedback. If the work meets all requirements,
        respond with the word APPROVED at the start of your response followed by
        a brief explanation. Otherwise list exactly what needs to change.
        """

        case Worker.assign(reviewer_pid, review_task) do
          {:ok, review_text} ->
            review_result = %{
              role: reviewer_agent.role,
              task: reviewer_agent.task,
              result: review_text,
              status: :done
            }

            next_acc = updated_acc ++ [review_result]

            if approved?(review_text) do
              Logger.info("Review loop APPROVED at iteration #{iter}")
              next_acc
            else
              do_review_loop(
                worker_pid, worker_agent,
                reviewer_pid, reviewer_agent,
                max, iter + 1,
                review_text,
                next_acc
              )
            end

          {:error, reason} ->
            Logger.warning("Reviewer failed at iter #{iter}: #{inspect(reason)}")
            updated_acc
        end
    end
  end

  # ── Private Helpers ──────────────────────────────────────────────────

  defp approved?(text) do
    text
    |> String.trim()
    |> String.upcase()
    |> String.starts_with?("APPROVED")
  end
end
