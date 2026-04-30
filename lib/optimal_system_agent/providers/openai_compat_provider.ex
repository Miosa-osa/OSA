defmodule OptimalSystemAgent.Providers.OpenAICompatProvider do
  @moduledoc """
  Consolidated OpenAI-compatible provider — handles 13 providers through one module.

  Instead of 13 near-identical wrapper modules, this single module stores provider
  configs and dispatches to OpenAICompat.chat/5 with the correct URL, API key, and model.

  Covers: openai, groq, deepseek, together, fireworks, perplexity, mistral,
  openrouter, qwen, moonshot, zhipu, volcengine, baichuan.
  """

  alias OptimalSystemAgent.Providers.OpenAICompat

  @provider_configs %{
    openai: %{
      default_url: "https://api.openai.com/v1",
      default_model: "gpt-4o",
      available_models: ["gpt-4o", "gpt-4o-mini", "o3", "o3-mini", "o4-mini"]
    },
    groq: %{
      default_url: "https://api.groq.com/openai/v1",
      default_model: "llama-3.3-70b-versatile",
      available_models: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"]
    },
    deepseek: %{
      default_url: "https://api.deepseek.com/v1",
      default_model: "deepseek-chat",
      available_models: ["deepseek-chat", "deepseek-reasoner"]
    },
    together: %{
      default_url: "https://api.together.xyz/v1",
      default_model: "meta-llama/Llama-3.3-70B-Instruct-Turbo"
    },
    fireworks: %{
      default_url: "https://api.fireworks.ai/inference/v1",
      default_model: "accounts/fireworks/models/llama-v3p3-70b-instruct"
    },
    perplexity: %{
      default_url: "https://api.perplexity.ai",
      default_model: "sonar-pro"
    },
    mistral: %{
      default_url: "https://api.mistral.ai/v1",
      default_model: "mistral-large-latest"
    },
    openrouter: %{
      default_url: "https://openrouter.ai/api/v1",
      default_model: "meta-llama/llama-3.3-70b-instruct",
      extra_headers: [
        {"HTTP-Referer", "https://github.com/Miosa-osa/OSA"},
        {"X-Title", "OSA"}
      ]
    },
    qwen: %{
      default_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      default_model: "qwen-max"
    },
    moonshot: %{
      default_url: "https://api.moonshot.cn/v1",
      default_model: "moonshot-v1-128k"
    },
    zhipu: %{
      default_url: "https://open.bigmodel.cn/api/paas/v4",
      default_model: "glm-4-plus"
    },
    volcengine: %{
      default_url: "https://ark.cn-beijing.volces.com/api/v3",
      default_model: "doubao-pro-128k"
    },
    baichuan: %{
      default_url: "https://api.baichuan-ai.com/v1",
      default_model: "Baichuan4"
    }
  }

  @doc "Return provider atoms handled by this module."
  def providers, do: Map.keys(@provider_configs)

  @doc "Return the default model for a given provider."
  def default_model(provider), do: get_config!(provider).default_model

  @doc "Return available models for a given provider."
  def available_models(provider) do
    config = get_config!(provider)
    Map.get(config, :available_models, [config.default_model])
  end

  @doc "Send a chat completion request through the named provider."
  def chat(provider, messages, opts \\ []) do
    config = get_config!(provider)

    api_key = Application.get_env(:optimal_system_agent, :"#{provider}_api_key")

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :"#{provider}_model", config.default_model)

    url = Application.get_env(:optimal_system_agent, :"#{provider}_url", config.default_url)

    opts =
      opts
      |> Keyword.delete(:model)
      |> maybe_add_headers(config)
      |> maybe_extend_timeout(model)

    case OpenAICompat.chat(url, api_key, model, messages, opts) do
      {:error, "API key not configured"} ->
        {:error, "#{provider |> to_string() |> String.upcase()}_API_KEY not configured"}

      other ->
        other
    end
  end

  @doc "Send a streaming chat completion request through the named provider."
  def chat_stream(provider, messages, callback, opts \\ []) do
    config = get_config!(provider)

    api_key = Application.get_env(:optimal_system_agent, :"#{provider}_api_key")

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :"#{provider}_model", config.default_model)

    url = Application.get_env(:optimal_system_agent, :"#{provider}_url", config.default_url)

    opts =
      opts
      |> Keyword.delete(:model)
      |> maybe_add_headers(config)
      |> maybe_extend_timeout(model)

    case OpenAICompat.chat_stream(url, api_key, model, messages, callback, opts) do
      {:error, "API key not configured"} ->
        {:error, "#{provider |> to_string() |> String.upcase()}_API_KEY not configured"}

      other ->
        other
    end
  end

  defp maybe_add_headers(opts, %{extra_headers: headers}),
    do: Keyword.put(opts, :extra_headers, headers)

  defp maybe_add_headers(opts, _config), do: opts

  # Reasoning models (o3, deepseek-reasoner, kimi) need 600s timeout
  defp maybe_extend_timeout(opts, model) do
    if OpenAICompat.reasoning_model?(model) and not Keyword.has_key?(opts, :receive_timeout) do
      Keyword.put(opts, :receive_timeout, 600_000)
    else
      opts
    end
  end

  defp get_config!(provider) do
    case Map.get(@provider_configs, provider) do
      nil -> raise ArgumentError, "Unknown compat provider: #{provider}"
      config -> config
    end
  end
end
