defmodule OptimalSystemAgent.Providers.Registry do
  @moduledoc """
  LLM provider routing, fallback chains, and dynamic registration.

  Supports 17 providers across 3 categories:
  - Local:             ollama
  - OpenAI-compatible: openai, groq, together, fireworks, deepseek,
                       perplexity, mistral, replicate,
                       qwen, moonshot, zhipu, volcengine, baichuan
  - Native APIs:       anthropic, google, cohere

  ## Public API (backward-compatible)

      # Basic usage
      OptimalSystemAgent.Providers.Registry.chat(messages)

      # With options
      OptimalSystemAgent.Providers.Registry.chat(messages, provider: :groq, temperature: 0.5)

      # List all registered providers
      OptimalSystemAgent.Providers.Registry.list_providers()

      # Get info about a specific provider
      OptimalSystemAgent.Providers.Registry.provider_info(:groq)

  ## Fallback Chains

  Set a fallback chain in config:

      config :optimal_system_agent, :fallback_chain, [:anthropic, :openai, :groq, :ollama]

  The registry will try each provider in order until one succeeds.

  ## 4-Tier Model Routing

  1. Process-type default (thinking = best, tool execution = fast)
  2. Task-type override (coding tasks upgrade tier)
  3. Fallback chain when rate-limited
  4. Local fallback (Ollama always available)
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Providers

  # Canonical provider registry — maps atom → module
  @providers %{
    # Local
    ollama: Providers.Ollama,

    # OpenAI and OpenAI-compatible
    openai: Providers.OpenAI,
    groq: Providers.Groq,
    together: Providers.Together,
    fireworks: Providers.Fireworks,
    deepseek: Providers.DeepSeek,
    perplexity: Providers.Perplexity,
    mistral: Providers.Mistral,
    replicate: Providers.Replicate,

    # Native API providers
    anthropic: Providers.Anthropic,
    google: Providers.Google,
    cohere: Providers.Cohere,

    # Chinese providers (OpenAI-compatible)
    qwen: Providers.Qwen,
    moonshot: Providers.Moonshot,
    zhipu: Providers.Zhipu,
    volcengine: Providers.Volcengine,
    baichuan: Providers.Baichuan
  }

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Send a chat completion request to the configured LLM provider.

  Options:
    - `:provider`    — override the default provider atom
    - `:temperature` — sampling temperature (default: 0.7)
    - `:max_tokens`  — maximum tokens to generate
    - `:tools`       — list of tool definitions

  Returns `{:ok, %{content: String.t(), tool_calls: list()}}` or `{:error, reason}`.
  """
  @spec chat(list(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def chat(messages, opts \\ []) do
    provider = Keyword.get(opts, :provider) || default_provider()
    opts_without_provider = Keyword.delete(opts, :provider)

    case Map.get(@providers, provider) do
      nil ->
        {:error, "Unknown provider: #{provider}. Available: #{inspect(Map.keys(@providers))}"}

      module ->
        call_with_fallback(provider, module, messages, opts_without_provider)
    end
  end

  @doc """
  List all registered provider atoms.
  """
  @spec list_providers() :: list(atom())
  def list_providers, do: Map.keys(@providers)

  @doc """
  Get information about a specific provider.

  Returns a map with `:name`, `:module`, `:default_model`, and `:configured?`.
  """
  @spec provider_info(atom()) :: {:ok, map()} | {:error, String.t()}
  def provider_info(provider) do
    case Map.get(@providers, provider) do
      nil ->
        {:error, "Unknown provider: #{provider}"}

      module ->
        info = %{
          name: provider,
          module: module,
          default_model: module.default_model(),
          configured?: provider_configured?(provider)
        }

        {:ok, info}
    end
  end

  @doc """
  Register a custom provider module at runtime.

  The module must implement the `OptimalSystemAgent.Providers.Behaviour`.
  This does not persist across restarts.
  """
  @spec register_provider(atom(), module()) :: :ok | {:error, String.t()}
  def register_provider(name, module) do
    GenServer.call(__MODULE__, {:register_provider, name, module})
  end

  @doc """
  Execute a chat with explicit fallback chain.

  Tries each provider in order, returning the first success.
  If all fail, returns the last error.
  """
  @spec chat_with_fallback(list(), list(atom()), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def chat_with_fallback(messages, chain, opts \\ []) do
    Enum.reduce_while(chain, {:error, "No providers in chain"}, fn provider, _acc ->
      case chat(messages, Keyword.put(opts, :provider, provider)) do
        {:ok, _} = result ->
          {:halt, result}

        {:error, reason} ->
          Logger.warning("Provider #{provider} failed in fallback chain: #{reason}")
          {:cont, {:error, reason}}
      end
    end)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    providers = @providers
    Logger.info("Provider registry initialized with #{map_size(providers)} providers (default: #{default_provider()})")
    Logger.info("Providers: #{Map.keys(providers) |> Enum.join(", ")}")
    {:ok, %{extra_providers: %{}}}
  end

  @impl true
  def handle_call({:register_provider, name, module}, _from, state) do
    # Validate the module implements the behaviour
    if function_exported?(module, :chat, 2) and
         function_exported?(module, :name, 0) and
         function_exported?(module, :default_model, 0) do
      new_state = put_in(state[:extra_providers][name], module)
      Logger.info("Registered custom provider: #{name} -> #{module}")
      {:reply, :ok, new_state}
    else
      {:reply, {:error, "Module #{module} does not implement Providers.Behaviour"}, state}
    end
  end

  # --- Private ---

  defp call_with_fallback(provider, module, messages, opts) do
    case apply_provider(module, messages, opts) do
      {:ok, _} = result ->
        result

      {:error, reason} = err ->
        fallback_chain = Application.get_env(:optimal_system_agent, :fallback_chain, [])

        remaining_chain =
          fallback_chain
          |> Enum.drop_while(&(&1 == provider))
          |> then(fn
            # If provider wasn't in chain, try the whole chain
            chain when chain == fallback_chain -> chain
            # Otherwise use remainder after the failing provider
            [_ | rest] -> rest
            [] -> []
          end)

        if remaining_chain == [] do
          Logger.error("Provider #{provider} failed, no fallback configured: #{reason}")
          err
        else
          Logger.warning("Provider #{provider} failed: #{reason}. Trying fallback chain: #{inspect(remaining_chain)}")
          chat_with_fallback(messages, remaining_chain, opts)
        end
    end
  end

  defp apply_provider(module, messages, opts) do
    try do
      module.chat(messages, opts)
    rescue
      e ->
        Logger.error("Provider module #{module} raised: #{Exception.message(e)}")
        {:error, "Provider error: #{Exception.message(e)}"}
    end
  end

  defp provider_configured?(:ollama), do: true

  defp provider_configured?(provider) do
    key = :"#{provider}_api_key"
    case Application.get_env(:optimal_system_agent, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp default_provider do
    Application.get_env(:optimal_system_agent, :default_provider, :ollama)
  end
end
