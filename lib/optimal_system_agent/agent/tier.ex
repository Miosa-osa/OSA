defmodule OptimalSystemAgent.Agent.Tier do
  @moduledoc """
  Model tier system for agent dispatch.

  Maps agent tiers to LLM model configurations across all 18 providers:
    :elite      → opus-class (claude-opus-5, gpt-5.6-sol, gemini-3.1-pro-preview)
    :specialist → sonnet-class (claude-sonnet-5, gpt-5.6-terra, gemini-3.6-flash)
    :utility    → haiku-class (claude-haiku-4-5, gpt-5.6-luna, gemini-3.5-flash-lite)

  Ollama uses dynamic tier detection — scans installed models, sorts by size,
  and maps largest→elite, medium→specialist, smallest→utility.

  Based on: OSA Agent v3.3 tier system
  """

  require Logger

  @type tier :: :elite | :specialist | :utility

  # ── Tier → Model Mapping (all 18 providers) ─────────────────────

  # All models at every tier MUST support tool/function calling.
  # No model under 30B parameters. Think Haiku/Sonnet/Opus — all capable,
  # just different speed/cost/quality tradeoffs.
  @tier_models %{
    # --- Frontier providers ---
    anthropic: %{
      elite: "claude-opus-5",
      specialist: "claude-sonnet-5",
      utility: "claude-haiku-4-5"
    },
    openai: %{
      elite: "gpt-5.6-sol",
      specialist: "gpt-5.6-terra",
      utility: "gpt-5.6-luna"
    },
    # `gemini-2.0-flash` held :utility until 2026-08-01; Google shut it down
    # 2026-06-01, so that tier resolved to a 404. The 2.5 pair that replaced it
    # shuts down 2026-10-16 — inside the 90-day guard — so all three tiers now
    # sit on the current 3.x family.
    google: %{
      elite: "gemini-3.1-pro-preview",
      specialist: "gemini-3.6-flash",
      utility: "gemini-3.5-flash-lite"
    },
    # Both ids were RETIRED 2026-07-24 — all three tiers were dead. Note that
    # :elite is no longer a different MODEL: DeepSeek V4 moved thinking onto a
    # request parameter, so reasoning depth is now chosen by effort, not by id.
    deepseek: %{
      elite: "deepseek-v4-pro",
      specialist: "deepseek-v4-flash",
      utility: "deepseek-v4-flash"
    },
    # `mistral-large-latest` now resolves to Large 3, which is CHEAPER and
    # weaker than Medium 3.5 — so the old elite/specialist ordering was
    # inverted. Medium 3.5 is Mistral's frontier agentic/coding model.
    mistral: %{
      elite: "mistral-medium-latest",
      specialist: "mistral-large-latest",
      utility: "mistral-small-latest"
    },
    # The undated `command-r-plus` / `command-r` aliases were shut down
    # 2025-09-15 — all three tiers were dead ids.
    cohere: %{
      elite: "command-a-plus-05-2026",
      specialist: "command-a-plus-05-2026",
      utility: "command-r-08-2024"
    },

    # --- Fast inference providers (all 70B+ for tool calling) ---
    # Groq shuts down both Llama ids on 2026-08-16, and `qwen-qwq-32b` is gone
    # from its production model list — so all three tiers were about to break.
    groq: %{
      elite: "openai/gpt-oss-120b",
      specialist: "openai/gpt-oss-120b",
      utility: "openai/gpt-oss-20b"
    },
    # `llama-v3p3-70b-instruct` resolves on Fireworks but its card says
    # "Serverless: Not supported" — dedicated-GPU only, so every serverless
    # call 400s. `qwen3-30b-a3b` is not on the serverless list either.
    fireworks: %{
      elite: "accounts/fireworks/models/kimi-k2p7-code",
      specialist: "accounts/fireworks/models/deepseek-v4-flash",
      utility: "accounts/fireworks/models/gpt-oss-20b"
    },
    together: %{
      elite: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
      specialist: "Qwen/Qwen3-30B-A3B",
      utility: "Qwen/Qwen3-30B-A3B"
    },
    # All three tiers pointed at `meta/llama-3.3-70b-instruct`, which 404s on
    # Replicate — the slug was never published there. See Providers.Replicate.
    replicate: %{
      elite: "openai/gpt-oss-120b",
      specialist: "openai/gpt-oss-120b",
      utility: "openai/gpt-oss-20b"
    },

    # --- Aggregator / search providers ---
    # OpenRouter namespaces Anthropic ids with a DOT where Anthropic's own API
    # uses a DASH: the live catalog has `anthropic/claude-haiku-4.5`, NOT
    # `anthropic/claude-haiku-4-5`. Ids with no version dot (`claude-opus-5`,
    # `claude-sonnet-5`) are identical under both conventions, which is exactly
    # why this went unnoticed — only the :utility tier was broken, and only on
    # OpenRouter. Verified against the live GET /api/v1/models catalog
    # (2026-08-01). Anything built by concatenating "anthropic/" onto an
    # Anthropic API id is unsafe for any dotted version.
    openrouter: %{
      elite: "anthropic/claude-opus-5",
      specialist: "anthropic/claude-sonnet-5",
      utility: "anthropic/claude-haiku-4.5"
    },
    perplexity: %{
      elite: "sonar-pro",
      specialist: "sonar-pro",
      utility: "sonar"
    },

    # --- Chinese / regional providers ---
    qwen: %{
      elite: "qwen3.5-72b",
      specialist: "qwen3-coder-30b",
      utility: "qwen-plus"
    },
    zhipu: %{
      elite: "glm-4.5-air",
      specialist: "glm-4-plus",
      utility: "glm-4-flash"
    },
    moonshot: %{
      elite: "moonshot-v1-128k",
      specialist: "moonshot-v1-32k",
      utility: "moonshot-v1-32k"
    },
    baichuan: %{
      elite: "Baichuan4",
      specialist: "Baichuan4",
      utility: "Baichuan3-Turbo"
    },
    volcengine: %{
      elite: "doubao-pro-128k",
      specialist: "doubao-pro-32k",
      utility: "doubao-pro-32k"
    },

    # --- Ollama Cloud (all models must support tool calling) ---
    # Updated 2026-07-20 — verified live against ollama.com/api/show per model.
    ollama_cloud: %{
      # Z.ai flagship — long-horizon agentic + coding (1M ctx)
      elite: "glm-5.2:cloud",
      # native multimodal agentic (512K ctx)
      specialist: "minimax-m3:cloud",
      # OpenAI open-weight, fast (131K ctx). Replaced gemini-3-flash-preview,
      # which Ollama Cloud retired 2026-07-15 (/api/show → "was retired").
      utility: "gpt-oss:20b-cloud"
    },

    # --- Local providers (dynamic, auto-detect best installed) ---
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
      thinking: 10_000,
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
      thinking: 5_000,
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
      thinking: 2_000,
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

  Resolution precedence (high -> low), matching the `delegate` spawn path:

      settings override (agent_overrides)  >  agent .md `model:`  >
        agent tier -> provider tier-model  >  provider auto model

  Previously this ignored the agent entirely and always returned the provider
  auto model, so a named agent's declared tier/model never took effect on this
  path.
  """
  @spec model_for_agent(String.t()) :: String.t()
  def model_for_agent(agent_name) when is_binary(agent_name) do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
    agent_def = OptimalSystemAgent.Agents.Registry.get(agent_name)

    tier =
      OptimalSystemAgent.Agents.Config.tier_override(agent_name) ||
        (agent_def && agent_def[:tier]) || :specialist

    OptimalSystemAgent.Agents.Config.model_override(agent_name) ||
      (agent_def && agent_def[:model]) ||
      model_for(tier, provider)
  end

  def model_for_agent(_), do: auto_model(Application.get_env(:optimal_system_agent, :default_provider, :ollama))

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
  def max_agents(:elite), do: 50
  def max_agents(:specialist), do: 30
  def max_agents(:utility), do: 10

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
  @spec detect_ollama_tiers() :: {:ok, map()} | {:error, :no_models}
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

        {:ok, mapping}

      _ ->
        # No models or connection failed — clear any stale cache
        :persistent_term.put(:osa_ollama_tiers, %{})
        {:error, :no_models}
    end
  end

  @doc "Get Ollama model sizes for display (returns map of name => size_bytes)."
  @spec ollama_model_sizes() :: map()
  def ollama_model_sizes do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case safe_list_ollama_models(url) do
      {:ok, models} -> Map.new(models, fn m -> {m.name, m.size} end)
      _ -> %{}
    end
  end

  @doc "List all providers that have tier mappings configured."
  @spec supported_providers() :: [atom()]
  def supported_providers, do: Map.keys(@tier_models)

  # ── Private ────────────────────────────────────────────────────────

  defp auto_model(provider) do
    key = :"#{provider}_model"

    Application.get_env(:optimal_system_agent, key) ||
      Application.get_env(
        :optimal_system_agent,
        :default_model,
        OptimalSystemAgent.Providers.AnthropicModels.default_model()
      )
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

  @doc """
  Set a manual tier override. Takes priority over size-based auto-assignment.
  Call detect_ollama_tiers() after to apply.
  """
  @spec set_tier_override(tier(), String.t()) :: :ok
  def set_tier_override(tier, model) when tier in [:elite, :specialist, :utility] do
    overrides = get_tier_overrides()
    :persistent_term.put(:osa_tier_overrides, Map.put(overrides, tier, model))
    :ok
  end

  @doc "Clear a manual tier override."
  @spec clear_tier_override(tier()) :: :ok
  def clear_tier_override(tier) when tier in [:elite, :specialist, :utility] do
    overrides = get_tier_overrides()
    :persistent_term.put(:osa_tier_overrides, Map.delete(overrides, tier))
    :ok
  end

  @doc "Get all manual tier overrides."
  @spec get_tier_overrides() :: map()
  def get_tier_overrides do
    try do
      :persistent_term.get(:osa_tier_overrides)
    rescue
      ArgumentError -> %{}
    end
  end

  # Assign tiers from a size-sorted (descending) list of models.
  # User overrides take priority, then size-based assignment fills the rest.
  # With 1 model: all tiers use it.
  # With 2 models: elite=largest, specialist+utility=smallest.
  # With 3+: elite=largest, specialist=middle, utility=smallest.
  defp assign_ollama_tiers([]), do: %{}

  defp assign_ollama_tiers([only]) do
    apply_overrides(%{elite: only.name, specialist: only.name, utility: only.name})
  end

  defp assign_ollama_tiers([large, small]) do
    apply_overrides(%{elite: large.name, specialist: small.name, utility: small.name})
  end

  defp assign_ollama_tiers([large | rest]) do
    mid_idx = div(length(rest), 2)
    mid = Enum.at(rest, mid_idx)
    small = List.last(rest)

    apply_overrides(%{elite: large.name, specialist: mid.name, utility: small.name})
  end

  # Merge user overrides on top of size-based assignments
  defp apply_overrides(mapping) do
    overrides = get_tier_overrides()
    Map.merge(mapping, overrides)
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
