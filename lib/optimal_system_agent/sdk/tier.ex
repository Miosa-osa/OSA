defmodule OptimalSystemAgent.SDK.Tier do
  @moduledoc """
  SDK wrapper for the Tier system.

  Query available models, tiers, and token budgets across 18 LLM providers.
  """

  alias OptimalSystemAgent.Agent.Tier

  @doc """
  Get the model name for a tier on a given provider.

  ## Example

      OSA.SDK.Tier.model_for(:elite, :anthropic)
      # => "claude-opus-4-6"
  """
  @spec model_for(Tier.tier(), atom()) :: String.t()
  def model_for(tier, provider) do
    Tier.model_for(tier, provider)
  end

  @doc """
  Get the model for a named agent (tier-based routing).
  """
  @spec model_for_agent(String.t()) :: String.t()
  def model_for_agent(agent_name) do
    Tier.model_for_agent(agent_name)
  end

  @doc """
  Get token budget breakdown for a tier.

  Returns `%{system: int, agent: int, tools: int, conversation: int,
             execution: int, reasoning: int, buffer: int, total: int}`
  """
  @spec budget_for(Tier.tier()) :: map()
  def budget_for(tier) do
    Tier.budget_for(tier)
  end

  @doc "Get total token budget for a tier."
  @spec total_budget(Tier.tier()) :: non_neg_integer()
  def total_budget(tier), do: Tier.total_budget(tier)

  @doc "Map complexity score (1-10) to tier."
  @spec tier_for_complexity(integer()) :: Tier.tier()
  def tier_for_complexity(complexity), do: Tier.tier_for_complexity(complexity)

  @doc "Get full tier info (budget, temperature, max_iterations, max_agents)."
  @spec tier_info(Tier.tier()) :: map()
  def tier_info(tier), do: Tier.tier_info(tier)

  @doc "Get all three tier configurations."
  @spec all() :: map()
  def all, do: Tier.all_tiers()

  @doc "List all supported LLM providers."
  @spec supported_providers() :: [atom()]
  def supported_providers, do: Tier.supported_providers()

  @doc "Max response tokens for a tier."
  @spec max_response_tokens(Tier.tier()) :: non_neg_integer()
  def max_response_tokens(tier), do: Tier.max_response_tokens(tier)

  @doc "Temperature setting for a tier."
  @spec temperature(Tier.tier()) :: float()
  def temperature(tier), do: Tier.temperature(tier)

  @doc "Max concurrent agents for a tier."
  @spec max_agents(Tier.tier()) :: non_neg_integer()
  def max_agents(tier), do: Tier.max_agents(tier)

  @doc "Max Loop iterations for a tier."
  @spec max_iterations(Tier.tier()) :: non_neg_integer()
  def max_iterations(tier), do: Tier.max_iterations(tier)
end
