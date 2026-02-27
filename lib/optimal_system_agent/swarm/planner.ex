defmodule OptimalSystemAgent.Swarm.Planner do
  @moduledoc """
  Decomposes complex tasks into subtasks and assigns agent roles.

  Uses the configured LLM to analyse the task and produce a structured
  execution plan. Falls back to a sensible default plan when the LLM is
  unavailable or returns unparseable JSON.

  ## Output format

      %{
        pattern: :parallel | :pipeline | :debate | :review,
        agents: [
          %{role: :researcher, task: "Research the best approaches for X"},
          %{role: :coder, task: "Implement the chosen approach"},
          %{role: :reviewer, task: "Review the implementation for bugs and style"}
        ],
        synthesis_strategy: :merge | :vote | :chain,
        rationale: "Short explanation of why this plan was chosen"
      }

  ## Patterns

  - `:parallel` — agents work independently; results are merged
  - `:pipeline` — agent A passes output to agent B which passes to C
  - `:debate`   — multiple agents propose; a critic picks/merges the best
  - `:review`   — coder works, reviewer checks, iterate up to N times
  """
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @valid_roles ~w(researcher coder reviewer planner critic writer tester architect)a
  @valid_patterns ~w(parallel pipeline debate review)a
  @valid_strategies ~w(merge vote chain)a

  @max_agents 5

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Analyse a task and produce an execution plan.
  Returns a plan map on success. On failure returns a safe fallback plan.
  """
  def decompose(task_description, opts \\ []) do
    max_agents = Keyword.get(opts, :max_agents, @max_agents)

    Logger.info(
      "Planner decomposing task (max_agents=#{max_agents}): #{String.slice(task_description, 0, 100)}..."
    )

    case call_llm(task_description, max_agents) do
      {:ok, plan} ->
        Logger.info(
          "Planner produced plan: pattern=#{plan.pattern} agents=#{length(plan.agents)}"
        )

        plan

      {:error, reason} ->
        Logger.warning("Planner LLM call failed (#{inspect(reason)}), using fallback plan")
        fallback_plan(task_description)
    end
  end

  # ── Private — LLM decomposition ─────────────────────────────────────

  defp call_llm(task_description, max_agents) do
    system_prompt = """
    You are a task decomposition specialist. Given a complex task, you must produce
    a multi-agent execution plan as a single JSON object — no prose, no markdown,
    just the raw JSON.

    Choose the most appropriate pattern:
    - "parallel": agents work independently on separate aspects (best for research + implementation + review)
    - "pipeline": agent A produces output → agent B refines → agent C finalises (best for sequential refinement)
    - "debate": multiple agents propose solutions → critic picks the best (best for design decisions)
    - "review": one agent works, one reviews, iterate (best for code quality)

    Available roles: researcher, coder, reviewer, planner, critic, writer, tester, architect

    Maximum agents: #{max_agents}. Do not exceed this.

    Required JSON schema:
    {
      "pattern": "parallel" | "pipeline" | "debate" | "review",
      "agents": [
        {"role": "<role>", "task": "<specific subtask for this agent>"},
        ...
      ],
      "synthesis_strategy": "merge" | "vote" | "chain",
      "rationale": "<one sentence explaining why this plan fits the task>"
    }

    Rules:
    - Each agent task must be specific and self-contained
    - The synthesis_strategy must match the pattern (parallel→merge, pipeline→chain, debate→vote, review→chain)
    - Do not add fields beyond the schema above
    - Keep agent count between 2 and #{max_agents}
    """

    messages = [
      %{role: "system", content: system_prompt},
      %{
        role: "user",
        content: "Decompose this task into a multi-agent plan:\n\n#{task_description}"
      }
    ]

    case Providers.chat(messages, temperature: 0.3) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        parse_plan(content)

      {:ok, %{content: content}} ->
        {:error, "LLM returned empty content: #{inspect(content)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_plan(content) do
    # Strip potential markdown fences around the JSON
    json_str =
      content
      |> String.trim()
      |> strip_markdown_fences()

    case Jason.decode(json_str) do
      {:ok, raw} ->
        build_plan(raw)

      {:error, _} ->
        # Attempt to extract JSON object from within prose
        case extract_json_object(content) do
          {:ok, raw} ->
            build_plan(raw)

          :error ->
            {:error, "Could not parse JSON from LLM output: #{String.slice(content, 0, 200)}"}
        end
    end
  end

  defp strip_markdown_fences(content) do
    content
    |> String.replace(~r/^```(?:json)?\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim()
  end

  defp extract_json_object(content) do
    case Regex.run(~r/\{[\s\S]*\}/, content) do
      [json_str] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> :error
        end

      nil ->
        :error
    end
  end

  defp build_plan(raw) when is_map(raw) do
    with {:ok, pattern} <- validate_pattern(raw["pattern"]),
         {:ok, agents} <- validate_agents(raw["agents"]),
         {:ok, strategy} <- validate_strategy(raw["synthesis_strategy"], pattern) do
      plan = %{
        pattern: pattern,
        agents: agents,
        synthesis_strategy: strategy,
        rationale: raw["rationale"] || "LLM-generated plan"
      }

      {:ok, plan}
    end
  end

  defp build_plan(_), do: {:error, "LLM returned non-map JSON"}

  defp validate_pattern(p) when is_binary(p) do
    atom = String.to_existing_atom(p)

    if atom in @valid_patterns do
      {:ok, atom}
    else
      {:error, "Invalid pattern: #{p}"}
    end
  rescue
    _ -> {:error, "Unknown pattern atom: #{inspect(p)}"}
  end

  defp validate_pattern(_), do: {:error, "Pattern must be a string"}

  defp validate_agents(agents) when is_list(agents) and length(agents) >= 1 do
    validated =
      agents
      |> Enum.take(@max_agents)
      |> Enum.flat_map(fn agent ->
        case validate_agent(agent) do
          {:ok, a} ->
            [a]

          {:error, reason} ->
            Logger.warning("Planner: skipping invalid agent spec (#{reason}): #{inspect(agent)}")
            []
        end
      end)

    if validated == [] do
      {:error, "No valid agents in plan"}
    else
      {:ok, validated}
    end
  end

  defp validate_agents(_), do: {:error, "agents must be a non-empty list"}

  defp validate_agent(%{"role" => role, "task" => task})
       when is_binary(role) and is_binary(task) and task != "" do
    atom =
      try do
        String.to_existing_atom(role)
      rescue
        _ -> nil
      end

    if atom in @valid_roles do
      {:ok, %{role: atom, task: task}}
    else
      {:error, "Unknown role: #{role}"}
    end
  end

  defp validate_agent(a), do: {:error, "agent missing role or task: #{inspect(a)}"}

  defp validate_strategy(s, _pattern) when is_binary(s) do
    atom =
      try do
        String.to_existing_atom(s)
      rescue
        _ -> nil
      end

    if atom in @valid_strategies do
      {:ok, atom}
    else
      {:error, "Unknown synthesis_strategy: #{s}"}
    end
  end

  # Infer strategy from pattern when it's missing or invalid
  defp validate_strategy(_, pattern) do
    {:ok, default_strategy(pattern)}
  end

  defp default_strategy(:parallel), do: :merge
  defp default_strategy(:pipeline), do: :chain
  defp default_strategy(:debate), do: :vote
  defp default_strategy(:review), do: :chain

  # ── Fallback plan ────────────────────────────────────────────────────

  # Used when the LLM is unavailable or returns garbage. Produces a safe
  # two-agent parallel plan: researcher + writer, always valid.
  defp fallback_plan(task_description) do
    %{
      pattern: :parallel,
      agents: [
        %{role: :researcher, task: "Research and analyse: #{task_description}"},
        %{role: :writer, task: "Write a comprehensive response for: #{task_description}"}
      ],
      synthesis_strategy: :merge,
      rationale: "Fallback parallel plan (LLM planner unavailable)"
    }
  end
end
