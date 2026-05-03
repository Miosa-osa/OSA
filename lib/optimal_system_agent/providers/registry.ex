defmodule OptimalSystemAgent.Providers.Registry do
  @moduledoc """
  LLM provider routing, fallback chains, and dynamic registration.

  Supports 18 providers across 3 categories:
  - Local:             ollama
  - OpenAI-compatible: openai, groq, together, fireworks, deepseek,
                       perplexity, mistral, replicate, openrouter,
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
  4. Local fallback (Ollama, if reachable)
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Providers
  alias OptimalSystemAgent.Providers.HealthChecker
  alias OptimalSystemAgent.Providers.ModelCatalog

  # Consolidated compat provider — one module handles 13 OpenAI-compatible APIs
  @compat Providers.OpenAICompatProvider

  # Canonical provider registry — maps atom → module | {:compat, atom}
  @providers Map.merge(
               %{
                 # Local
                 ollama: Providers.Ollama,

                 # OpenAI-compatible (consolidated through OpenAICompatProvider)
                 openai: {:compat, :openai},
                 groq: {:compat, :groq},
                 together: {:compat, :together},
                 fireworks: {:compat, :fireworks},
                 deepseek: {:compat, :deepseek},
                 perplexity: {:compat, :perplexity},
                 mistral: {:compat, :mistral},
                 openrouter: {:compat, :openrouter},

                 # Native API providers (custom protocol, not OpenAI-compatible)
                 anthropic: Providers.Anthropic,
                 google: Providers.Google,
                 cohere: Providers.Cohere,
                 replicate: Providers.Replicate,

                 # Chinese providers (OpenAI-compatible, consolidated)
                 qwen: {:compat, :qwen},
                 moonshot: {:compat, :moonshot},
                 zhipu: {:compat, :zhipu},
                 volcengine: {:compat, :volcengine},
                 baichuan: {:compat, :baichuan}
               },
               if Mix.env() == :test do
                 %{mock: OptimalSystemAgent.Test.MockProvider}
               else
                 %{}
               end
             )

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

  @doc "Return the effective model name for the current or given provider."
  @spec current_model(atom() | String.t() | nil) :: String.t()
  def current_model(provider \\ nil) do
    provider =
      case provider || default_provider() do
        p when is_binary(p) -> String.to_existing_atom(p)
        p -> p
      end

    case Application.get_env(:optimal_system_agent, :default_model) do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        case provider_info(provider) do
          {:ok, info} -> to_string(info.default_model)
          _ -> to_string(provider || "unknown")
        end
    end
  rescue
    _ -> Application.get_env(:optimal_system_agent, :default_model, "unknown") |> to_string()
  end

  @doc """
  Get information about a specific provider.

  Returns a map with `:name`, `:module`, `:default_model`, and `:configured?`.
  """
  @spec provider_info(atom()) :: {:ok, map()} | {:error, String.t()}
  def provider_info(provider) do
    case Map.get(@providers, provider) do
      nil ->
        {:error, "Unknown provider: #{provider}"}

      {:compat, prov} ->
        {:ok,
         %{
           name: provider,
           module: @compat,
           default_model: @compat.default_model(prov),
           available_models: @compat.available_models(prov),
           configured?: provider_configured?(provider)
         }}

      module when is_atom(module) ->
        models =
          if function_exported?(module, :available_models, 0) do
            module.available_models()
          else
            [module.default_model()]
          end

        {:ok,
         %{
           name: provider,
           module: module,
           default_model: module.default_model(),
           available_models: models,
           configured?: provider_configured?(provider)
         }}
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
  Stream a chat completion request through the configured provider.

  If the provider implements `chat_stream/3`, uses streaming.
  Otherwise falls back to synchronous `chat/2` and invokes the
  callback with the full result.

  The callback receives the same tuple types as `Behaviour.chat_stream/3`.
  """
  @spec chat_stream(list(), function(), keyword()) :: :ok | {:error, String.t()}
  def chat_stream(messages, callback, opts \\ []) do
    provider = Keyword.get(opts, :provider) || default_provider()
    opts_without_provider = Keyword.delete(opts, :provider)

    case Map.get(@providers, provider) do
      nil ->
        {:error, "Unknown provider: #{provider}. Available: #{inspect(Map.keys(@providers))}"}

      module ->
        case stream_with_fallback(provider, module, messages, callback, opts_without_provider) do
          :ok -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp fallback_sync_stream(module, messages, callback, opts) do
    case apply_provider(module, messages, opts) do
      {:ok, result} ->
        if result.content != "", do: callback.({:text_delta, result.content})
        callback.({:done, result})
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Execute a chat with explicit fallback chain.

  Tries each provider in order, returning the first success.
  If all fail, returns the last error.
  """
  @spec chat_with_fallback(list(), list(atom()), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def chat_with_fallback(messages, chain, opts \\ []) do
    available_chain =
      Enum.filter(chain, fn provider ->
        if HealthChecker.is_available?(provider) do
          true
        else
          Logger.warning(
            "Provider #{provider} skipped in fallback chain (circuit open or rate-limited)"
          )

          false
        end
      end)

    Enum.reduce_while(available_chain, {:error, "No providers in chain"}, fn provider, _acc ->
      case chat(messages, Keyword.put(opts, :provider, provider)) do
        {:ok, _} = result ->
          {:halt, result}

        {:error, {:rate_limited, retry_after}} ->
          HealthChecker.record_rate_limited(provider, retry_after)
          Logger.warning("Provider #{provider} rate-limited in fallback chain, trying next")
          {:cont, {:error, "rate-limited"}}

        {:error, reason} ->
          HealthChecker.record_failure(provider, reason)
          Logger.warning("Provider #{provider} failed in fallback chain: #{reason}")
          {:cont, {:error, reason}}
      end
    end)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    providers = @providers
    default = default_provider()

    Logger.info(
      "Provider registry initialized with #{map_size(providers)} providers (default: #{default})"
    )

    Logger.info("Providers: #{Map.keys(providers) |> Enum.join(", ")}")

    # Boot reachability check for Ollama.
    # If Ollama is unreachable at startup we mark it as excluded so it is
    # never tried in the fallback chain, preventing a flood of :econnrefused
    # log lines on every LLM call.
    ollama_reachable = ollama_reachable?()

    unless ollama_reachable do
      Logger.info(
        "[Providers.Registry] Ollama not reachable at boot — skipping in fallback chain"
      )
    end

    # Stash the boot-time decision in the process dictionary so private
    # chain-building helpers can read it without a self-GenServer-call.
    Process.put(:osa_ollama_excluded, not ollama_reachable)

    {:ok, %{extra_providers: %{}, ollama_excluded: not ollama_reachable}}
  end

  defp ollama_reachable? do
    OptimalSystemAgent.Providers.Ollama.reachable?()
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
    case with_retry(fn -> apply_provider(module, messages, opts) end) do
      {:ok, _} = result ->
        HealthChecker.record_success(provider)
        result

      {:error, {:rate_limited, retry_after}} = _rate_err ->
        HealthChecker.record_rate_limited(provider, retry_after)
        try_fallback_chain(provider, messages, opts, "rate-limited (HTTP 429)")

      {:error, reason} = err ->
        HealthChecker.record_failure(provider, reason)
        fallback_chain = Application.get_env(:optimal_system_agent, :fallback_chain, [])

        remaining_chain =
          fallback_chain
          |> Enum.drop_while(&(&1 == provider))
          |> then(fn
            chain when chain == fallback_chain -> chain
            [_ | rest] -> rest
            [] -> []
          end)
          |> filter_boot_excluded_providers()
          |> Enum.filter(&HealthChecker.is_available?/1)

        if remaining_chain == [] do
          Logger.error("Provider #{provider} failed, no fallback configured: #{reason}")
          err
        else
          Logger.warning(
            "Provider #{provider} failed: #{reason}. Trying fallback chain: #{inspect(remaining_chain)}"
          )

          chat_with_fallback(messages, remaining_chain, opts)
        end
    end
  end

  defp try_fallback_chain(failed_provider, messages, opts, reason) do
    fallback_chain = Application.get_env(:optimal_system_agent, :fallback_chain, [])

    remaining_chain =
      fallback_chain
      |> Enum.drop_while(&(&1 == failed_provider))
      |> then(fn
        chain when chain == fallback_chain -> chain
        [_ | rest] -> rest
        [] -> []
      end)
      |> filter_boot_excluded_providers()
      |> Enum.filter(&HealthChecker.is_available?/1)

    if remaining_chain == [] do
      Logger.error(
        "Provider #{failed_provider} #{reason}, no available fallback in chain: #{inspect(fallback_chain)}"
      )

      {:error, "Provider #{failed_provider} #{reason} and no fallback available"}
    else
      Logger.warning(
        "Provider #{failed_provider} #{reason}, trying next available: #{inspect(remaining_chain)}"
      )

      chat_with_fallback(messages, remaining_chain, opts)
    end
  end

  # Removes providers that were found unreachable at boot time.
  # Currently only :ollama is subject to a boot-time probe; all other
  # providers are key-configured and assumed available until a runtime
  # failure flips the circuit breaker.
  defp filter_boot_excluded_providers(chain) do
    if Process.get(:osa_ollama_excluded, false) do
      Enum.reject(chain, &(&1 == :ollama))
    else
      chain
    end
  end

  defp stream_with_fallback(provider, module, messages, callback, opts) do
    result = with_retry(fn -> try_stream_provider(module, messages, callback, opts) end)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        fallback_chain = Application.get_env(:optimal_system_agent, :fallback_chain, [])

        remaining_chain =
          fallback_chain
          |> Enum.drop_while(&(&1 == provider))
          |> then(fn
            chain when chain == fallback_chain -> chain
            [_ | rest] -> rest
            [] -> []
          end)

        if remaining_chain == [] do
          Logger.error("Provider #{provider} stream failed, no fallback: #{reason}")
          {:error, reason}
        else
          Logger.warning(
            "Provider #{provider} stream failed: #{reason}. Trying fallback chain: #{inspect(remaining_chain)}"
          )

          # Try each fallback provider
          Enum.reduce_while(remaining_chain, {:error, reason}, fn fb_provider, _acc ->
            case Map.get(@providers, fb_provider) do
              nil ->
                {:cont, {:error, "Unknown fallback provider: #{fb_provider}"}}

              fb_module ->
                case try_stream_provider(fb_module, messages, callback, opts) do
                  :ok ->
                    {:halt, :ok}

                  {:error, r} ->
                    Logger.warning("Fallback stream provider #{fb_provider} failed: #{r}")
                    {:cont, {:error, r}}
                end
            end
          end)
        end
    end
  end

  defp try_stream_provider({:compat, provider}, messages, callback, opts) do
    # Compat providers now support chat_stream via OpenAICompatProvider
    try do
      @compat.chat_stream(provider, messages, callback, opts)
    rescue
      e ->
        Logger.warning(
          "Compat provider #{provider} streaming failed: #{Exception.message(e)}, falling back to sync"
        )

        fallback_sync_stream({:compat, provider}, messages, callback, opts)
    end
  end

  defp try_stream_provider(module, messages, callback, opts) when is_atom(module) do
    if function_exported?(module, :chat_stream, 3) do
      try do
        Logger.info("[Registry] Calling #{module}.chat_stream/3")

        case module.chat_stream(messages, callback, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Provider #{module} chat_stream failed: #{inspect(reason)} — falling back to sync"
            )

            fallback_sync_stream(module, messages, callback, opts)
        end
      rescue
        e ->
          Logger.error("Provider #{module} chat_stream raised: #{Exception.message(e)}")
          fallback_sync_stream(module, messages, callback, opts)
      end
    else
      fallback_sync_stream(module, messages, callback, opts)
    end
  end

  # Retry wrapper for rate-limited responses.
  #
  # - On `{:error, {:rate_limited, seconds}}` — sleep for `seconds` (capped at 60s),
  #   then retry.
  # - On `{:error, {:rate_limited, nil}}` — use exponential backoff: 1s, 2s, 4s.
  # - Any other error — return immediately without retrying.
  # - Max 3 attempts total (1 initial + 2 retries).
  # - Streaming responses return `:ok` on success; the retry logic handles both
  #   `{:ok, _}` and bare `:ok`.
  @max_retries 3
  @backoff_base_ms 1_000

  defp with_retry(fun, attempt \\ 1) do
    result = fun.()

    case result do
      {:error, {:rate_limited, retry_after}} when attempt <= @max_retries ->
        sleep_ms =
          if is_integer(retry_after) and retry_after > 0 do
            min(retry_after, 60) * 1_000
          else
            round(@backoff_base_ms * :math.pow(2, attempt - 1))
          end

        Logger.warning(
          "Rate limited (attempt #{attempt}/#{@max_retries}). " <>
            "Retrying in #{div(sleep_ms, 1_000)}s..."
        )

        Process.sleep(sleep_ms)
        with_retry(fun, attempt + 1)

      _other ->
        result
    end
  end

  defp apply_provider({:compat, provider}, messages, opts) do
    try do
      @compat.chat(provider, messages, opts)
    rescue
      e ->
        Logger.error("Provider #{provider} raised: #{Exception.message(e)}")
        {:error, "Provider error: #{Exception.message(e)}"}
    end
  end

  defp apply_provider(module, messages, opts) when is_atom(module) do
    try do
      module.chat(messages, opts)
    rescue
      e ->
        Logger.error("Provider module #{module} raised: #{Exception.message(e)}")
        {:error, "Provider error: #{Exception.message(e)}"}
    end
  end

  @doc """
  Return the context window size (in tokens) for a given model.

  Falls back to `:max_context_tokens` app env, then 128_000.
  Ollama models use `num_ctx` from the model info endpoint when available,
  otherwise fall back to a conservative 8_192.
  """
  @model_context_windows %{
    # Anthropic
    "claude-opus-4-7" => 1_000_000,
    "claude-opus-4-6" => 1_000_000,
    "claude-sonnet-4-6" => 1_000_000,
    "claude-haiku-4-5" => 200_000,
    # Older Claude models
    "claude-3-5-sonnet-20241022" => 200_000,
    "claude-3-5-haiku-20241022" => 200_000,
    "claude-3-opus-20240229" => 200_000,
    # OpenAI
    "gpt-5.5" => 1_050_000,
    "gpt-5.5-pro" => 1_050_000,
    "gpt-5.4" => 1_050_000,
    "gpt-5.4-mini" => 1_050_000,
    "gpt-5.4-nano" => 1_050_000,
    "gpt-5.3-codex" => 1_050_000,
    "gpt-5.2" => 1_050_000,
    "gpt-5.2-pro" => 1_050_000,
    "gpt-5.2-codex" => 1_050_000,
    "gpt-4.1" => 1_047_576,
    "gpt-4.1-mini" => 1_047_576,
    "gpt-4.1-nano" => 1_047_576,
    "gpt-4o" => 128_000,
    "gpt-4o-mini" => 128_000,
    "o3" => 200_000,
    "o3-mini" => 200_000,
    "o4-mini" => 200_000,
    # Google
    "gemini-2.5-pro" => 1_048_576,
    "gemini-2.5-flash" => 1_048_576,
    "gemini-2.0-flash" => 1_048_576,
    # DeepSeek
    "deepseek-v4-pro" => 1_000_000,
    "deepseek-v4-flash" => 1_000_000,
    "deepseek-chat" => 128_000,
    "deepseek-reasoner" => 128_000,
    # Groq (context varies by model)
    "llama-3.3-70b-versatile" => 128_000,
    "llama-3.1-8b-instant" => 131_072,
    "mixtral-8x7b-32768" => 32_768,
    # Mistral
    "mistral-large-latest" => 128_000,
    "mistral-small-latest" => 128_000,
    # Cohere
    "command-r-plus" => 128_000,
    "command-r" => 128_000
  }

  @spec context_window(String.t()) :: pos_integer()
  def context_window(model) when is_binary(model) do
    case ModelCatalog.context_window(model) do
      {:ok, ctx} ->
        ctx

      :error ->
        context_window_from_static_or_ollama(model)
    end
  end

  def context_window(_) do
    case current_model() do
      "unknown" -> Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
      model -> context_window(model)
    end
  end

  defp context_window_from_static_or_ollama(model) do
    case Map.get(@model_context_windows, model) do
      nil ->
        # Try prefix match for model aliases and dated variants.
        matched =
          Enum.find(@model_context_windows, fn {key, _v} ->
            String.starts_with?(model, key)
          end)

        case matched do
          {_key, size} ->
            size

          nil ->
            # Check Ollama model info for num_ctx.
            case get_ollama_context(model) do
              {:ok, ctx} -> ctx
              _ -> Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
            end
        end

      size ->
        size
    end
  end

  defp get_ollama_context(model) do
    # Check ETS cache first
    case :ets.whereis(:osa_context_cache) do
      :undefined ->
        :ok

      _ ->
        case :ets.lookup(:osa_context_cache, model) do
          [{^model, cached_ctx}] -> return_cached(cached_ctx)
          _ -> :ok
        end
    end
    |> case do
      {:ok, _ctx} = hit -> hit
      _ -> fetch_ollama_context(model)
    end
  end

  defp return_cached(ctx), do: {:ok, ctx}

  defp fetch_ollama_context(model) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case Req.post("#{url}/api/show", json: %{name: model}, receive_timeout: 3_000, retry: false) do
      {:ok, %{status: 200, body: %{"model_info" => info}}} ->
        # Ollama returns context length in model_info under various keys
        ctx =
          info
          |> Enum.find_value(fn
            {k, v} when is_integer(v) and v > 0 ->
              if String.contains?(k, "context_length"), do: v

            _ ->
              nil
          end)

        if ctx do
          # Cache the result
          case :ets.whereis(:osa_context_cache) do
            :undefined -> :ok
            _ -> :ets.insert(:osa_context_cache, {model, ctx})
          end

          {:ok, ctx}
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Returns true if the provider has a configured API key (or is Ollama, which needs none
  but must be reachable). Ollama reachability is checked via TCP probe with 1s timeout.
  """
  @spec provider_configured?(atom()) :: boolean()
  def provider_configured?(:ollama) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case Req.get(url <> "/api/version", receive_timeout: 2_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> true
      _ -> false
    end
  end

  def provider_configured?(provider) do
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
