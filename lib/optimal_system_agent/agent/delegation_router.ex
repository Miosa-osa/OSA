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
  @vision_phrases ~w(screenshot screenshots image images diagram diagrams photo photos photograph)

  # Soft requirements narrow the model pool but must never block a delegation
  # on their own: vision is easily a false positive from an incidental keyword,
  # and a provider pool may simply have no vision or huge-context model. Only
  # :tools is a hard requirement.
  @soft_requirements [:vision, :large_context]

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
    |> maybe_add(:vision, mentions_vision?(normalized))
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

    find = fn reqs ->
      Enum.find_value(candidates, fn provider ->
        model = model_for.(tier, provider)

        if configured?.(provider) and
             compatible?(reqs, provider, model, tool_call, context_window, vision_capable) do
          {provider, model}
        end
      end)
    end

    # Walk the relaxation ladder: full requirements first, then progressively
    # drop soft requirements so a missing vision/large-context model degrades
    # to the best tools-capable model instead of blocking the delegation.
    selected =
      Enum.find_value(relaxation_ladder(requirements), fn reqs ->
        case find.(reqs) do
          {provider, model} -> {provider, model, reqs}
          nil -> nil
        end
      end)

    case selected do
      {provider, model, met} ->
        config
        |> Map.put(:provider, provider)
        |> Map.put(:model, model)
        |> Map.put(:model_reason, selection_reason(provider, model, met, requirements -- met))
        |> Map.put(:model_requirements, Enum.map(requirements, &to_string/1))

      nil ->
        requirements_text = describe_requirements(requirements)

        config
        |> Map.put(
          :routing_error,
          "no configured model is known to satisfy: #{requirements_text}"
        )
        |> Map.put(:model_reason, "delegation blocked because no capable model was found")
        |> Map.put(:model_requirements, Enum.map(requirements, &to_string/1))
    end
  end

  # Full requirement set first, then the same set with each soft requirement
  # dropped in turn (vision before large_context). Deduped, hard requirements
  # (:tools) never dropped.
  defp relaxation_ladder(requirements) do
    @soft_requirements
    |> Enum.reduce([requirements], fn soft, [current | _] = acc ->
      if soft in current, do: [current -- [soft] | acc], else: acc
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp selection_reason(provider, model, met, []) do
    "selected #{provider}/#{model} for task requirements: " <> describe_requirements(met)
  end

  defp selection_reason(provider, model, met, dropped) do
    "selected #{provider}/#{model} for task requirements: " <>
      describe_requirements(met) <>
      " (no configured model satisfied #{describe_requirements(dropped)}; proceeding without it)"
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

  # Word-boundary match so incidental substrings (imagemagick, visualize,
  # reimagine) do not force a vision requirement onto a plain code task.
  defp mentions_vision?(text),
    do: Enum.any?(@vision_phrases, &Regex.match?(~r/\b#{&1}\b/u, text))
  defp maybe_add(list, item, true), do: list ++ [item]
  defp maybe_add(list, _item, false), do: list
end
