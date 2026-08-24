defmodule OptimalSystemAgent.Swarm.Patterns do
  @moduledoc """
  Four swarm execution patterns + named preset loader.

  Patterns:
    :parallel    — all agents work independently, results merged
    :pipeline    — each agent's output feeds the next
    :debate      — N-1 proposers in parallel, last agent is the critic
    :review_loop — worker + reviewer iterate until APPROVED or max_iterations
  """
  require Logger

  alias OptimalSystemAgent.Orchestrator

  @presets_path "priv/swarms/patterns.json"

  # ---------------------------------------------------------------------------
  # Parallel
  # ---------------------------------------------------------------------------

  @doc """
  All agents work simultaneously on their assigned sub-tasks.
  Returns results in the same order as configs.

  Supported `opts` (both exist so the timeout/cap behaviour below is testable
  against the REAL `async_stream` machinery rather than a re-implementation):

    * `:runner`  — 1-arity fun invoked per config. Defaults to
      `Orchestrator.run_subagent/1`.
    * `:timeout` — per-agent timeout in ms. Defaults to 10 minutes.
  """
  def parallel(parent_id, configs, opts \\ []) do
    Logger.info("[Swarm.Patterns] parallel — #{length(configs)} agents")

    runner = Keyword.get(opts, :runner, &Orchestrator.run_subagent/1)
    timeout = Keyword.get(opts, :timeout, 600_000)
    depth = Keyword.get(opts, :depth, 0)

    results =
      OptimalSystemAgent.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        configs,
        fn config ->
          runner.(with_lineage(config, parent_id, depth))
        end,
        # `length(configs)` was no cap at all: a 40-agent swarm started 40
        # concurrent subagent Loops, each with its own provider connection,
        # context window and spend. The delegate path bounds exactly this with
        # `delegate_concurrency_cap/0` (the `:max_fleet_agents` setting); the
        # swarm path never adopted it. async_stream QUEUES beyond the cap, so
        # every config still runs — just not all at once.
        max_concurrency: min(length(configs), Orchestrator.delegate_concurrency_cap()),
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        # A timeout is a FAILURE, not output. This arm used to return
        # `{:ok, "[Agent timed out]"}`, so a killed agent that produced nothing
        # was indistinguishable from one that succeeded: it counted toward
        # completion tallies and its placeholder string was handed to the
        # synthesizer as if it were work. The delegate path was fixed the same
        # way (`Orchestrator.dispatch` classifies `:exit, {:timeout, _}` as
        # `{:error, :timeout}`); this path was missed.
        {:exit, :timeout} ->
          {:error, :timeout}

        {:exit, reason} ->
          {:error, inspect(reason)}
      end)

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  @doc """
  Sequential chain. Each agent receives the previous agent's output prepended
  to its task, enabling iterative refinement.
  """
  def pipeline(parent_id, configs, opts \\ []) do
    Logger.info("[Swarm.Patterns] pipeline — #{length(configs)} agents")
    depth = Keyword.get(opts, :depth, 0)

    {results, _} =
      Enum.map_reduce(configs, nil, fn config, prev_output ->
        task =
          if prev_output do
            "## Previous step output\n#{prev_output}\n\n## Your task\n#{config.task}"
          else
            config.task
          end

        config = config |> with_lineage(parent_id, depth) |> Map.put(:task, task)
        result = Orchestrator.run_subagent(config)

        output =
          case result do
            {:ok, text} -> text
            {:error, _} -> nil
          end

        {result, output}
      end)

    {:ok, results}
  end

  # ---------------------------------------------------------------------------
  # Debate
  # ---------------------------------------------------------------------------

  @doc """
  First N-1 agents propose in parallel. Last agent is the critic/evaluator
  and receives all proposals. Falls back to parallel if fewer than 2 agents.
  """
  def debate(parent_id, configs, opts \\ []) do
    Logger.info("[Swarm.Patterns] debate — #{length(configs)} agents")
    depth = Keyword.get(opts, :depth, 0)

    if length(configs) < 2 do
      Logger.warning("[Swarm.Patterns] debate requires ≥2 agents, falling back to parallel")
      parallel(parent_id, configs, opts)
    else
      {proposers, [evaluator_config]} = Enum.split(configs, length(configs) - 1)

      # Run proposers in parallel
      proposer_results =
        OptimalSystemAgent.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          proposers,
          fn config ->
            Orchestrator.run_subagent(with_lineage(config, parent_id, depth))
          end,
          # Same cap as `parallel/3` — an uncapped fan-out here is the identical
          # defect, just reached through a different pattern.
          max_concurrency: min(length(proposers), Orchestrator.delegate_concurrency_cap()),
          timeout: 600_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, {:ok, text}} -> text
          {:ok, {:error, _}} -> "[Agent failed]"
          _ -> "[Agent failed]"
        end)

      # Build evaluator task with all proposals
      proposals_text =
        proposers
        |> Enum.zip(proposer_results)
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {{config, text}, idx} ->
          role = Map.get(config, :role, "Agent #{idx}")
          "### Proposal #{idx} (#{role})\n#{text}"
        end)

      evaluator_task =
        "## Proposals to evaluate\n\n#{proposals_text}\n\n## Your task\n#{evaluator_config.task}"

      evaluator_config =
        evaluator_config
        |> with_lineage(parent_id, depth)
        |> Map.put(:task, evaluator_task)

      evaluator_result = Orchestrator.run_subagent(evaluator_config)

      all_results = Enum.map(proposer_results, &{:ok, &1}) ++ [evaluator_result]
      {:ok, all_results}
    end
  end

  # ---------------------------------------------------------------------------
  # Review Loop
  # ---------------------------------------------------------------------------

  @doc """
  Two-agent loop: worker produces/revises, reviewer critiques.
  Iterates until reviewer says "APPROVED" or max_iterations is reached.
  """
  def review_loop(parent_id, configs, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 3)
    depth = Keyword.get(opts, :depth, 0)
    Logger.info("[Swarm.Patterns] review_loop max_iterations=#{max_iterations}")

    case configs do
      [worker_config, reviewer_config | _] ->
        run_review_loop(parent_id, worker_config, reviewer_config, max_iterations, depth)

      [single | _] ->
        Logger.warning("[Swarm.Patterns] review_loop needs ≥2 agents, running single")
        result = Orchestrator.run_subagent(with_lineage(single, parent_id, depth))
        {:ok, [result]}

      [] ->
        {:error, :no_agents}
    end
  end

  defp run_review_loop(_parent_id, _worker_cfg, _reviewer_cfg, max_iter, _depth)
       when max_iter < 1 do
    Logger.warning(
      "[Swarm.Patterns] review_loop max_iterations=#{max_iter} < 1, returning empty result"
    )

    {:ok, [{:ok, "[no iterations]"}]}
  end

  defp run_review_loop(parent_id, worker_cfg, reviewer_cfg, max_iter, depth) do
    {final_output, _iterations, approved} =
      Enum.reduce_while(1..max_iter, {nil, 0, false}, fn iteration,
                                                         {prev_output, _iter, _approved} ->
        # Worker task (with reviewer feedback if this is a revision)
        worker_task =
          if prev_output do
            "## Reviewer feedback\n#{prev_output}\n\n## Your task (revision #{iteration})\n#{worker_cfg.task}"
          else
            worker_cfg.task
          end

        worker_result =
          worker_cfg
          |> with_lineage(parent_id, depth)
          |> Map.put(:task, worker_task)
          |> Orchestrator.run_subagent()

        worker_output =
          case worker_result do
            {:ok, text} -> text
            {:error, reason} -> "[Worker failed: #{inspect(reason)}]"
          end

        # Reviewer evaluates worker output
        reviewer_task =
          "## Worker output (iteration #{iteration})\n#{worker_output}\n\n## Your task\n#{reviewer_cfg.task}\n\nIf approved, start your response with 'APPROVED:'. Otherwise provide specific feedback."

        reviewer_result =
          reviewer_cfg
          |> with_lineage(parent_id, depth)
          |> Map.put(:task, reviewer_task)
          |> Orchestrator.run_subagent()

        reviewer_output =
          case reviewer_result do
            {:ok, text} -> text
            {:error, _} -> "[Reviewer failed]"
          end

        # Require "approved:" (with colon) to avoid matching "approves"/"approval"/"approvingly"
        approved? = reviewer_output |> String.downcase() |> String.starts_with?("approved:")

        if approved? or iteration == max_iter do
          {:halt, {worker_output, iteration, approved?}}
        else
          {:cont, {reviewer_output, iteration, false}}
        end
      end)

    note =
      if approved,
        do: "",
        else: "\n\n[Note: max iterations (#{max_iter}) reached without explicit approval]"

    {:ok, [{:ok, final_output <> note}]}
  end

  # ---------------------------------------------------------------------------
  # Lineage
  # ---------------------------------------------------------------------------

  # Stamp a config with its parent session AND the parent's delegation depth, so
  # `Orchestrator.run_subagent/1` increments from the true nesting level. Without
  # the depth, every orchestrate-spawned child started at depth 1 and the
  # fork-bomb ceiling in `ToolFilter.apply_delegation_depth_guard` was never
  # reached on this path.
  defp with_lineage(config, parent_id, depth) do
    config
    |> Map.put(:parent_session_id, parent_id)
    |> Map.put(:delegation_depth, depth)
  end

  # ---------------------------------------------------------------------------
  # Dispatch facade
  # ---------------------------------------------------------------------------

  @doc """
  Single entry point that turns a caller's plain task string + a pattern name
  into a real multi-agent run and returns ONE synthesized string.

  Pattern names accepted (string or atom): "parallel", "pipeline", "debate",
  "review"/"review_loop", "pact", "auto". Unknown names fall back to :auto.
  This wires the swarm patterns into the `orchestrate` tool and the
  POST /swarm/launch route so the advertised `strategy`/`pattern` actually
  changes behavior instead of silently running a single agent.
  """
  @spec dispatch(String.t() | atom(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch(pattern, parent_id, task, opts \\ []) when is_binary(task) do
    result =
      case normalize_pattern(pattern) do
        :parallel -> parallel(parent_id, build_configs(:parallel, task, opts), opts)
        :pipeline -> pipeline(parent_id, build_configs(:pipeline, task, opts), opts)
        :debate -> debate(parent_id, build_configs(:debate, task, opts), opts)
        :review_loop -> review_loop(parent_id, build_configs(:review_loop, task, opts), opts)
        :pact -> pipeline(parent_id, build_configs(:pact, task, opts), opts)
        :auto -> auto_dispatch(parent_id, task, opts)
      end

    case result do
      {:ok, results} -> {:ok, flatten_results(results)}
      {:error, _} = err -> err
      other -> {:ok, flatten_results(other)}
    end
  end

  @doc "Normalize a pattern name (string/atom) to a known pattern atom; :auto fallback."
  @spec normalize_pattern(String.t() | atom()) :: atom()
  def normalize_pattern(pattern) do
    pattern
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> case do
      "parallel" -> :parallel
      "pipeline" -> :pipeline
      "debate" -> :debate
      "review" -> :review_loop
      "review_loop" -> :review_loop
      "pact" -> :pact
      "auto" -> :auto
      _ -> :auto
    end
  end

  # Decompose a single task string into role-specialized sub-agent configs.
  # A caller may fully override the config list via opts[:configs].
  defp build_configs(pattern, task, opts) do
    case Keyword.get(opts, :configs) do
      [_ | _] = configs -> configs
      _ -> default_configs(pattern, task)
    end
  end

  defp default_configs(:pact, task) do
    [
      %{
        task:
          "Plan the approach for the following goal. Produce a concrete, ordered plan.\n\nGoal: #{task}",
        role: "planner",
        tier: :specialist
      },
      %{
        task:
          "Execute the plan for the following goal, implementing the required changes.\n\nGoal: #{task}",
        role: "implementer",
        tier: :specialist
      },
      %{
        task:
          "Coordinate and integrate the work done so far for the following goal, resolving conflicts.\n\nGoal: #{task}",
        role: "coordinator",
        tier: :specialist
      },
      %{
        task:
          "Test and verify the result for the following goal. Report pass/fail and any gaps.\n\nGoal: #{task}",
        role: "tester",
        tier: :specialist
      }
    ]
  end

  defp default_configs(:pipeline, task) do
    [
      %{
        task: "Research and outline an approach for: #{task}",
        role: "researcher",
        tier: :specialist
      },
      %{
        task: "Implement the following, using the prior research: #{task}",
        role: "implementer",
        tier: :specialist
      },
      %{
        task: "Review and finalize the following, fixing any issues: #{task}",
        role: "reviewer",
        tier: :specialist
      }
    ]
  end

  defp default_configs(:debate, task) do
    [
      %{task: "Propose a solution for: #{task}", role: "proposer-a", tier: :specialist},
      %{
        task: "Propose a DIFFERENT, alternative solution for: #{task}",
        role: "proposer-b",
        tier: :specialist
      },
      %{
        task: "Evaluate the proposals and produce the best synthesized answer for: #{task}",
        role: "critic",
        tier: :specialist
      }
    ]
  end

  defp default_configs(:review_loop, task) do
    [
      %{task: task, role: "worker", tier: :specialist},
      %{
        task: "Review the worker's output for correctness and completeness for: #{task}",
        role: "reviewer",
        tier: :specialist
      }
    ]
  end

  defp default_configs(_parallel_or_auto, task) do
    [
      %{task: task, role: "agent-1", tier: :specialist},
      %{task: task, role: "agent-2", tier: :specialist}
    ]
  end

  # :auto — a genuine (LLM-free) heuristic decision: multi-step / long tasks get
  # a pipeline decomposition, simple ones run as a single agent.
  defp auto_dispatch(parent_id, task, opts) do
    if complex_task?(task) do
      pipeline(parent_id, build_configs(:pipeline, task, opts), opts)
    else
      result =
        Orchestrator.run_subagent(%{
          task: task,
          parent_session_id: parent_id,
          role: "agent",
          tier: :specialist
        })

      {:ok, [result]}
    end
  end

  defp complex_task?(task) do
    String.length(task) > 240 or
      Regex.match?(~r/\b(and then|after that|multiple|several|steps?|phases?|pipeline)\b/i, task)
  end

  defp flatten_results(results) when is_list(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n---\n\n", fn {res, idx} ->
      case res do
        {:ok, text} when is_binary(text) -> "### Agent #{idx}\n#{text}"
        {:error, reason} -> "### Agent #{idx} (failed)\n#{inspect(reason)}"
        text when is_binary(text) -> "### Agent #{idx}\n#{text}"
        other -> "### Agent #{idx}\n#{inspect(other)}"
      end
    end)
  end

  defp flatten_results(other), do: inspect(other)

  # ---------------------------------------------------------------------------
  # Named Presets
  # ---------------------------------------------------------------------------

  @doc "Load a named preset config from priv/swarms/patterns.json."
  def get_pattern(name) when is_binary(name) do
    case load_presets() do
      {:ok, presets} ->
        case Map.get(presets, name) do
          nil -> {:error, :not_found}
          config -> {:ok, config}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all known swarm pattern names. Single source of truth is
  `OptimalSystemAgent.Agent.Orchestrator.Patterns` (also surfaced by the command
  center) so the tool schema, /swarm/launch, and any UI stay in agreement.
  """
  def list_patterns do
    names =
      OptimalSystemAgent.Agent.Orchestrator.Patterns.list_patterns()
      |> Enum.map(fn {name, _desc} -> name end)

    {:ok, names}
  end

  defp load_presets do
    path = Application.app_dir(:optimal_system_agent, @presets_path)

    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      {:ok, data}
    else
      _ ->
        # Try relative path (dev mode)
        case File.read(@presets_path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, data} -> {:ok, data}
              _ -> {:error, :invalid_json}
            end

          _ ->
            {:error, :not_found}
        end
    end
  end
end
