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
  """
  def parallel(parent_id, configs, _opts \\ []) do
    Logger.info("[Swarm.Patterns] parallel — #{length(configs)} agents")

    results =
      OptimalSystemAgent.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        configs,
        fn config -> Orchestrator.run_subagent(Map.put(config, :parent_session_id, parent_id)) end,
        max_concurrency: length(configs),
        timeout: 600_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> {:ok, "[Agent timed out]"}
        {:exit, reason} -> {:error, inspect(reason)}
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
  def pipeline(parent_id, configs, _opts \\ []) do
    Logger.info("[Swarm.Patterns] pipeline — #{length(configs)} agents")

    {results, _} =
      Enum.map_reduce(configs, nil, fn config, prev_output ->
        task =
          if prev_output do
            "## Previous step output\n#{prev_output}\n\n## Your task\n#{config.task}"
          else
            config.task
          end

        config = Map.put(config, :parent_session_id, parent_id) |> Map.put(:task, task)
        result = Orchestrator.run_subagent(config)

        output = case result do
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
  def debate(parent_id, configs, _opts \\ []) do
    Logger.info("[Swarm.Patterns] debate — #{length(configs)} agents")

    if length(configs) < 2 do
      Logger.warning("[Swarm.Patterns] debate requires ≥2 agents, falling back to parallel")
      parallel(parent_id, configs)
    else
      {proposers, [evaluator_config]} = Enum.split(configs, length(configs) - 1)

      # Run proposers in parallel
      proposer_results =
        OptimalSystemAgent.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          proposers,
          fn config -> Orchestrator.run_subagent(Map.put(config, :parent_session_id, parent_id)) end,
          max_concurrency: length(proposers),
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
        |> Map.put(:parent_session_id, parent_id)
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
    Logger.info("[Swarm.Patterns] review_loop max_iterations=#{max_iterations}")

    case configs do
      [worker_config, reviewer_config | _] ->
        run_review_loop(parent_id, worker_config, reviewer_config, max_iterations)
      [single | _] ->
        Logger.warning("[Swarm.Patterns] review_loop needs ≥2 agents, running single")
        result = Orchestrator.run_subagent(Map.put(single, :parent_session_id, parent_id))
        {:ok, [result]}
      [] ->
        {:error, :no_agents}
    end
  end

  defp run_review_loop(_parent_id, _worker_cfg, _reviewer_cfg, max_iter) when max_iter < 1 do
    Logger.warning("[Swarm.Patterns] review_loop max_iterations=#{max_iter} < 1, returning empty result")
    {:ok, [{:ok, "[no iterations]"}]}
  end

  defp run_review_loop(parent_id, worker_cfg, reviewer_cfg, max_iter) do
    {final_output, _iterations, approved} =
      Enum.reduce_while(1..max_iter, {nil, 0, false}, fn iteration, {prev_output, _iter, _approved} ->
        # Worker task (with reviewer feedback if this is a revision)
        worker_task =
          if prev_output do
            "## Reviewer feedback\n#{prev_output}\n\n## Your task (revision #{iteration})\n#{worker_cfg.task}"
          else
            worker_cfg.task
          end

        worker_result =
          worker_cfg
          |> Map.put(:parent_session_id, parent_id)
          |> Map.put(:task, worker_task)
          |> Orchestrator.run_subagent()

        worker_output = case worker_result do
          {:ok, text} -> text
          {:error, reason} -> "[Worker failed: #{inspect(reason)}]"
        end

        # Reviewer evaluates worker output
        reviewer_task =
          "## Worker output (iteration #{iteration})\n#{worker_output}\n\n## Your task\n#{reviewer_cfg.task}\n\nIf approved, start your response with 'APPROVED:'. Otherwise provide specific feedback."

        reviewer_result =
          reviewer_cfg
          |> Map.put(:parent_session_id, parent_id)
          |> Map.put(:task, reviewer_task)
          |> Orchestrator.run_subagent()

        reviewer_output = case reviewer_result do
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
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List all available named patterns."
  def list_patterns do
    case load_presets() do
      {:ok, presets} -> {:ok, Map.keys(presets)}
      err -> err
    end
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
          _ -> {:error, :not_found}
        end
    end
  end
end
