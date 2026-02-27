defmodule OptimalSystemAgent.Agent.Tier do
  @moduledoc """
  Model tier system for agent dispatch.

  Maps agent tiers to LLM model configurations across all 18 providers:
    :elite      → opus-class (claude-opus-4-6, gpt-4o, gemini-2.5-pro)
    :specialist → sonnet-class (claude-sonnet-4-6, gpt-4o-mini, gemini-2.0-flash)
    :utility    → haiku-class (claude-haiku-4-5, gpt-3.5-turbo, gemini-2.0-flash-lite)

  Ollama uses dynamic tier detection — scans installed models, sorts by size,
  and maps largest→elite, medium→specialist, smallest→utility.

  Based on: OSA Agent v3.3 tier system
  """

  alias OptimalSystemAgent.Agent.Roster

  require Logger

  @type tier :: :elite | :specialist | :utility

  # ── Tier → Model Mapping (all 18 providers) ─────────────────────

  @tier_models %{
    # --- Frontier providers ---
    anthropic: %{
      elite: "claude-opus-4-6",
      specialist: "claude-sonnet-4-6",
      utility: "claude-haiku-4-5-20251001"
    },
    openai: %{
      elite: "gpt-4o",
      specialist: "gpt-4o-mini",
      utility: "gpt-3.5-turbo"
    },
    google: %{
      elite: "gemini-2.5-pro",
      specialist: "gemini-2.0-flash",
      utility: "gemini-2.0-flash-lite"
    },
    deepseek: %{
      elite: "deepseek-reasoner",
      specialist: "deepseek-chat",
      utility: "deepseek-chat"
    },
    mistral: %{
      elite: "mistral-large-latest",
      specialist: "mistral-medium-latest",
      utility: "mistral-small-latest"
    },
    cohere: %{
      elite: "command-r-plus",
      specialist: "command-r",
      utility: "command-r"
    },

    # --- Fast inference providers ---
    groq: %{
      elite: "llama-3.3-70b-versatile",
      specialist: "llama-3.1-70b-versatile",
      utility: "llama-3.1-8b-instant"
    },
    fireworks: %{
      elite: "accounts/fireworks/models/llama-v3p3-70b-instruct",
      specialist: "accounts/fireworks/models/llama-v3p1-8b-instruct",
      utility: "accounts/fireworks/models/llama-v3p2-3b-instruct"
    },
    together: %{
      elite: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
      specialist: "meta-llama/Llama-3.1-8B-Instruct-Turbo",
      utility: "meta-llama/Llama-3.2-3B-Instruct-Turbo"
    },
    replicate: %{
      elite: "meta/llama-3.3-70b-instruct",
      specialist: "meta/llama-3.1-8b-instruct",
      utility: "meta/llama-3.2-3b-instruct"
    },

    # --- Aggregator / search providers ---
    openrouter: %{
      elite: "anthropic/claude-opus-4-6",
      specialist: "anthropic/claude-sonnet-4-6",
      utility: "anthropic/claude-haiku-4-5"
    },
    perplexity: %{
      elite: "sonar-pro",
      specialist: "sonar",
      utility: "sonar"
    },

    # --- Chinese / regional providers ---
    qwen: %{
      elite: "qwen-max",
      specialist: "qwen-plus",
      utility: "qwen-turbo"
    },
    zhipu: %{
      elite: "glm-4-plus",
      specialist: "glm-4",
      utility: "glm-4-flash"
    },
    moonshot: %{
      elite: "moonshot-v1-128k",
      specialist: "moonshot-v1-32k",
      utility: "moonshot-v1-8k"
    },
    baichuan: %{
      elite: "Baichuan4",
      specialist: "Baichuan3-Turbo",
      utility: "Baichuan3-Turbo-128k"
    },
    volcengine: %{
      elite: "doubao-pro-128k",
      specialist: "doubao-pro-32k",
      utility: "doubao-lite-32k"
    },

    # --- Local providers (dynamic) ---
    ollama: %{
      elite: :auto,
      specialist: :auto,
      utility: :auto
    }
  }

  # ── Token Budget per Tier ─────────────────────────────────────────
  # How many tokens each tier is allocated for a sub-agent turn

  @tier_budgets %{
    elite: %{
      system: 20_000,
      agent: 30_000,
      tools: 20_000,
      conversation: 60_000,
      execution: 75_000,
      reasoning: 40_000,
      buffer: 5_000,
      total: 250_000
    },
    specialist: %{
      system: 15_000,
      agent: 25_000,
      tools: 15_000,
      conversation: 50_000,
      execution: 60_000,
      reasoning: 30_000,
      buffer: 5_000,
      total: 200_000
    },
    utility: %{
      system: 8_000,
      agent: 12_000,
      tools: 8_000,
      conversation: 25_000,
      execution: 30_000,
      reasoning: 12_000,
      buffer: 5_000,
      total: 100_000
    }
  }

  # ── Public API ────────────────────────────────────────────────────

  @doc """
  Get the model name for a given tier and provider.
  For Ollama, uses dynamic detection based on installed models.
  Falls back to the default model if tier mapping isn't available.
  """
  @spec model_for(tier(), atom()) :: String.t()
  def model_for(tier, :ollama) do
    case ollama_tier_model(tier) do
      nil -> auto_model(:ollama)
      model -> model
    end
  end

  def model_for(tier, provider) do
    case get_in(@tier_models, [provider, tier]) do
      :auto -> auto_model(provider)
      nil -> auto_model(provider)
      model -> model
    end
  end

  @doc """
  Get the model for a specific agent by name.
  Looks up the agent's tier in the Roster, then maps to the current provider.
  """
  @spec model_for_agent(String.t()) :: String.t()
  def model_for_agent(agent_name) do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    case Roster.get(agent_name) do
      nil -> auto_model(provider)
      agent -> model_for(agent.tier, provider)
    end
  end

  @doc "Get the token budget for a tier."
  @spec budget_for(tier()) :: map()
  def budget_for(tier) do
    Map.get(@tier_budgets, tier, @tier_budgets.specialist)
  end

  @doc "Get the total token budget for a tier."
  @spec total_budget(tier()) :: non_neg_integer()
  def total_budget(tier) do
    budget_for(tier).total
  end

  @doc "Get the max tokens for a sub-agent response based on tier."
  @spec max_response_tokens(tier()) :: non_neg_integer()
  def max_response_tokens(:elite), do: 8_000
  def max_response_tokens(:specialist), do: 4_000
  def max_response_tokens(:utility), do: 2_000

  @doc """
  Select the optimal tier for a task based on complexity.
  Complexity 1-3 → utility, 4-6 → specialist, 7-10 → elite.
  """
  @spec tier_for_complexity(integer()) :: tier()
  def tier_for_complexity(complexity) when complexity <= 3, do: :utility
  def tier_for_complexity(complexity) when complexity <= 6, do: :specialist
  def tier_for_complexity(_complexity), do: :elite

  @doc """
  Get the number of max concurrent agents based on tier.
  Elite tasks get more agents since they're more complex.
  """
  @spec max_agents(tier()) :: non_neg_integer()
  def max_agents(:elite), do: 10
  def max_agents(:specialist), do: 6
  def max_agents(:utility), do: 3

  @doc """
  Get the temperature setting for a tier.
  Elite is more creative, utility is more deterministic.
  """
  @spec temperature(tier()) :: float()
  def temperature(:elite), do: 0.5
  def temperature(:specialist), do: 0.4
  def temperature(:utility), do: 0.2

  @doc "Get the max iterations for a sub-agent ReAct loop by tier."
  @spec max_iterations(tier()) :: non_neg_integer()
  def max_iterations(:elite), do: 25
  def max_iterations(:specialist), do: 15
  def max_iterations(:utility), do: 8

  @doc "Get tier display info."
  @spec tier_info(tier()) :: map()
  def tier_info(tier) do
    %{
      tier: tier,
      budget: budget_for(tier),
      max_agents: max_agents(tier),
      max_iterations: max_iterations(tier),
      temperature: temperature(tier),
      max_response_tokens: max_response_tokens(tier)
    }
  end

  @doc "List all tiers with their configurations."
  @spec all_tiers() :: map()
  def all_tiers do
    %{
      elite: tier_info(:elite),
      specialist: tier_info(:specialist),
      utility: tier_info(:utility)
    }
  end

  @doc """
  Detect installed Ollama models and cache tier assignments.
  Call at boot or when Ollama models change. Maps largest→elite,
  medium→specialist, smallest→utility based on model file size.
  """
  @spec detect_ollama_tiers() :: :ok
  def detect_ollama_tiers do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case safe_list_ollama_models(url) do
      {:ok, models} when models != [] ->
        sorted = Enum.sort_by(models, & &1.size, :desc)
        mapping = assign_ollama_tiers(sorted)
        :persistent_term.put(:osa_ollama_tiers, mapping)

        Logger.info(
          "[Tier] Ollama tiers: " <>
            Enum.map_join([:elite, :specialist, :utility], ", ", fn t ->
              "#{t}=#{mapping[t] || "none"}"
            end)
        )

        :ok

      _ ->
        # No models or connection failed — clear any stale cache
        :persistent_term.put(:osa_ollama_tiers, %{})
        :ok
    end
  end

  @doc "List all providers that have tier mappings configured."
  @spec supported_providers() :: [atom()]
  def supported_providers, do: Map.keys(@tier_models)

  # ── Private ────────────────────────────────────────────────────────

  defp auto_model(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key) ||
      Application.get_env(:optimal_system_agent, :default_model, "claude-sonnet-4-6")
  end

  # Fetch the cached Ollama tier model, falling back to auto_model
  defp ollama_tier_model(tier) do
    case safe_get_ollama_tiers() do
      %{} = mapping when map_size(mapping) > 0 ->
        Map.get(mapping, tier)

      _ ->
        nil
    end
  end

  defp safe_get_ollama_tiers do
    try do
      :persistent_term.get(:osa_ollama_tiers)
    rescue
      ArgumentError -> %{}
    end
  end

  # Assign tiers from a size-sorted (descending) list of models.
  # With 1 model: all tiers use it.
  # With 2 models: elite=largest, specialist+utility=smallest.
  # With 3+: elite=largest, specialist=middle, utility=smallest.
  defp assign_ollama_tiers([]), do: %{}

  defp assign_ollama_tiers([only]) do
    %{elite: only.name, specialist: only.name, utility: only.name}
  end

  defp assign_ollama_tiers([large, small]) do
    %{elite: large.name, specialist: small.name, utility: small.name}
  end

  defp assign_ollama_tiers([large | rest]) do
    mid_idx = div(length(rest), 2)
    mid = Enum.at(rest, mid_idx)
    small = List.last(rest)

    %{elite: large.name, specialist: mid.name, utility: small.name}
  end

  # Safe wrapper that doesn't crash if Ollama module isn't loaded or unreachable
  defp safe_list_ollama_models(url) do
    try do
      case Req.get("#{url}/api/tags", receive_timeout: 5_000) do
        {:ok, %{status: 200, body: %{"models" => models}}} ->
          parsed =
            Enum.map(models, fn m ->
              %{name: m["name"], size: m["size"] || 0}
            end)
            |> Enum.filter(fn m -> m.size > 0 end)

          {:ok, parsed}

        _ ->
          {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    end
  end
end
