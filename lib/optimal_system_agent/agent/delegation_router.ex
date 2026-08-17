defmodule OptimalSystemAgent.Agent.DelegationRouter do
  @moduledoc """
  Capability-aware model selection for delegated tasks.

  Explicit operator choices always win. Otherwise the router derives bounded
  requirements from the task and walks the configured provider fallback order,
  selecting the first model known to satisfy required tool use and context.
  Unknown capability data is treated as unknown rather than unsupported.
  """

  alias OptimalSystemAgent.Agent.Tier
  alias OptimalSystemAgent.Providers.{FallbackChain, ImageBudget, ModelLimits, Registry}

  @large_context_phrases [
    "entire repository",
    "whole repository",
    "codebase",
    "monorepo",
    "audit broadly"
  ]
  @vision_phrases ~w(screenshot image diagram photo visual attached)

  @doc "Resolve provider/model plus an operator-readable selection rationale."
  @spec resolve(String.t(), map(), keyword()) :: map()
  def resolve(task, config, opts \\ []) when is_binary(task) and is_map(config) do
    requirements = requirements(task)
    explicit_model = Map.get(config, :model)
    explicit_provider = Map.get(config, :provider)

    if is_binary(explicit_model) do
      config
      |> Map.put(:provider, explicit_provider || default_provider())
      |> Map.put(:model_reason, "explicit model selected by the delegating task")
      |> Map.put(:model_requirements, Enum.map(requirements, &to_string/1))
    else
      choose(task, config, requirements, opts)
    end
  end

  @doc "Derive model capabilities required by a delegated task."
  @spec requirements(String.t()) :: [atom()]
  def requirements(task) when is_binary(task) do
    normalized = String.downcase(task)

    [:tools]
    |> maybe_add(:large_context, contains_any?(normalized, @large_context_phrases))
    |> maybe_add(:vision, contains_any?(normalized, @vision_phrases))
  end

  defp choose(_task, config, requirements, opts) do
    tier = Map.get(config, :tier, :specialist)
    primary = Map.get(config, :provider) || default_provider()
    candidates = Keyword.get(opts, :candidates, candidate_providers(primary))
    configured? = Keyword.get(opts, :configured?, &Registry.provider_configured?/1)
    model_for = Keyword.get(opts, :model_for, &Tier.model_for/2)
    tool_call = Keyword.get(opts, :tool_call, &ModelLimits.tool_call/2)
    context_window = Keyword.get(opts, :context_window, &Registry.context_window/1)
    vision_capable = Keyword.get(opts, :vision_capable, &ImageBudget.vision_capable?/2)

    selected =
      Enum.find_value(candidates, fn provider ->
        model = model_for.(tier, provider)

        if configured?.(provider) and
             compatible?(
               requirements,
               provider,
               model,
               tool_call,
               context_window,
               vision_capable
             ) do
          {provider, model}
        end
      end) || {primary, model_for.(tier, primary)}

    {provider, model} = selected

    reason =
      "selected #{provider}/#{model} for task requirements: " <>
        describe_requirements(requirements)

    config
    |> Map.put(:provider, provider)
    |> Map.put(:model, model)
    |> Map.put(:model_reason, reason)
    |> Map.put(:model_requirements, Enum.map(requirements, &to_string/1))
  end

  defp compatible?(requirements, provider, model, tool_call, context_window, vision_capable) do
    tools_ok = :tools not in requirements or tool_call.(provider, model) != false

    context_ok =
      :large_context not in requirements or
        case context_window.(model) do
          size when is_integer(size) -> size >= 100_000
          _ -> false
        end

    vision_ok = :vision not in requirements or vision_capable.(provider, model)

    tools_ok and context_ok and vision_ok
  end

  defp candidate_providers(primary) do
    allowed = FallbackChain.cost_gated_chain(FallbackChain.chain(), primary)
    [primary | Enum.reject(allowed, &(&1 == primary))]
  end

  defp default_provider,
    do: Application.get_env(:optimal_system_agent, :default_provider, :ollama)

  defp describe_requirements(requirements) do
    requirements
    |> Enum.map(fn
      :tools -> "supports tools"
      :large_context -> "at least 100k context when known"
      :vision -> "vision-aware task"
    end)
    |> Enum.join(", ")
  end

  defp contains_any?(text, phrases), do: Enum.any?(phrases, &String.contains?(text, &1))
  defp maybe_add(list, item, true), do: list ++ [item]
  defp maybe_add(list, _item, false), do: list
end
