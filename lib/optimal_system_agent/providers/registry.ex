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
  alias OptimalSystemAgent.Providers.Resilience

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
                 baichuan: {:compat, :baichuan},

                 # Newly routed providers — previously offered by onboarding /
                 # declared in runtime.exs but missing routing here (the
                 # "Unknown provider: miosa" crash). All OpenAI-compatible.
                 miosa: {:compat, :miosa},
                 xai: {:compat, :xai},
                 cerebras: {:compat, :cerebras},
                 sambanova: {:compat, :sambanova},
                 hyperbolic: {:compat, :hyperbolic},
                 lmstudio: {:compat, :lmstudio},
                 llamacpp: {:compat, :llamacpp},

                 # Ollama Cloud — distinct entry reusing the native Ollama
                 # provider (pinned to ollama.com via OLLAMA_URL). Keeps the
                 # native /api/chat device-identity path (keyless when signed in).
                 ollama_cloud: Providers.Ollama
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
           available_models: catalog_models_for(provider) || @compat.available_models(prov),
           configured?: provider_configured?(provider)
         }}

      module when is_atom(module) ->
        fallback_models =
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
           available_models: catalog_models_for(provider) || fallback_models,
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
    # Same-provider retry (backoff, retry-after aware) runs *before* any
    # model/provider fallback. Only once these retries are exhausted do we
    # drop to the configured fallback chain below.
    retried =
      Resilience.with_retry(
        fn -> apply_provider(module, messages, opts) end,
        retry_opts(provider)
      )

    case retried do
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
    # 1. Native streaming with same-provider retry (backoff, retry-after aware,
    #    mid-stream error aware). Only after these retries are exhausted do we
    #    consider any model/provider fallback.
    on_retry = fn info -> notify_stream_retry(callback, info) end

    primary_result =
      if stream_capable?(module) do
        Resilience.with_retry(
          fn -> native_stream(module, messages, callback, opts) end,
          retry_opts(provider, on_retry)
        )
      else
        # Provider does not implement streaming — go straight to sync.
        fallback_sync_stream(module, messages, callback, opts)
      end

    case primary_result do
      :ok ->
        :ok

      {:error, _reason} ->
        # 2. Same-provider sync fallback (a plain request sometimes succeeds
        #    where a stream-only hiccup did not), then the model/provider chain.
        case fallback_sync_stream(module, messages, callback, opts) do
          :ok ->
            :ok

          {:error, sync_reason} ->
            stream_fallback_chain(provider, messages, callback, opts, sync_reason)
        end
    end
  end

  # Model/provider fallback for streaming — only reached after same-provider
  # retries (and a same-provider sync attempt) are exhausted.
  defp stream_fallback_chain(provider, messages, callback, opts, reason) do
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

    if remaining_chain == [] do
      Logger.error(
        "Provider #{provider} stream failed, no fallback: #{Resilience.reason_to_string(reason)}"
      )

      {:error, reason}
    else
      Logger.warning(
        "Provider #{provider} stream failed: #{Resilience.reason_to_string(reason)}. " <>
          "Trying fallback chain: #{inspect(remaining_chain)}"
      )

      Enum.reduce_while(remaining_chain, {:error, reason}, fn fb_provider, _acc ->
        case Map.get(@providers, fb_provider) do
          nil ->
            {:cont, {:error, "Unknown fallback provider: #{fb_provider}"}}

          fb_module ->
            case try_stream_provider(fb_module, messages, callback, opts) do
              :ok ->
                {:halt, :ok}

              {:error, r} ->
                Logger.warning(
                  "Fallback stream provider #{fb_provider} failed: #{Resilience.reason_to_string(r)}"
                )

                {:cont, {:error, r}}
            end
        end
      end)
    end
  end

  # True when the module can stream natively (so it is worth wrapping in the
  # same-provider retry loop rather than dropping straight to sync).
  defp stream_capable?({:compat, _provider}), do: true

  defp stream_capable?(module) when is_atom(module),
    do: function_exported?(module, :chat_stream, 3)

  # A single native streaming attempt — NO sync fallback. Returns
  # `:ok | {:error, reason}` so `Resilience.with_retry/2` can classify the
  # error and decide whether to retry the same provider.
  defp native_stream({:compat, provider}, messages, callback, opts) do
    @compat.chat_stream(provider, messages, callback, opts)
  rescue
    e -> {:error, "Compat provider #{provider} streaming raised: #{Exception.message(e)}"}
  end

  defp native_stream(module, messages, callback, opts) when is_atom(module) do
    Logger.info("[Registry] Calling #{module}.chat_stream/3 (native, retryable)")
    module.chat_stream(messages, callback, opts)
  rescue
    e -> {:error, "Provider #{module} chat_stream raised: #{Exception.message(e)}"}
  end

  # Build retry options for Resilience.with_retry: logs, emits a TUI-facing
  # `:provider_retry` system event, and (optionally) forwards to a stream
  # callback so a live stream can surface "retrying (n/max)…".
  defp retry_opts(provider, extra_on_retry \\ nil) do
    on_retry = fn info ->
      Logger.warning(
        "[resilience] #{provider} retry #{info.next_attempt}/#{info.max_attempts} " <>
          "in #{info.delay_ms}ms — #{Resilience.reason_to_string(info.reason)}"
      )

      emit_retry_event(provider, info)
      if is_function(extra_on_retry, 1), do: extra_on_retry.(info)
      :ok
    end

    [on_retry: on_retry]
  end

  defp emit_retry_event(provider, info) do
    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :provider_retry,
      provider: provider,
      attempt: info.next_attempt,
      max_attempts: info.max_attempts,
      delay_ms: info.delay_ms,
      reason: Resilience.reason_to_string(info.reason)
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp notify_stream_retry(callback, info) when is_function(callback, 1) do
    try do
      callback.(
        {:provider_retry,
         %{
           attempt: info.next_attempt,
           max_attempts: info.max_attempts,
           delay_ms: info.delay_ms,
           reason: Resilience.reason_to_string(info.reason)
         }}
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp notify_stream_retry(_callback, _info), do: :ok

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

  # Same-provider retry/backoff now lives in `Providers.Resilience`. The
  # registry composes it: `Resilience.with_retry/2` retries the same provider
  # on transient failures, and only when those are exhausted do the fallback
  # helpers below drop to an alternate model/provider.

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

  Resolution order:
    1. `Providers.Catalog` (models.dev-style, refreshable source of truth)
    2. Static `@fallback_context_windows` table (offline safety net)
    3. Ollama `/api/show` `num_ctx` (for local models)
    4. `:max_context_tokens` app env, then 128_000

  The static table is retained only as a fallback for when the Catalog is
  unavailable (e.g. GenServer not started) or does not yet know a model.
  """
  @fallback_context_windows %{
    # Anthropic — all Claude 4.x models have 1M context
    "claude-opus-4-6" => 1_000_000,
    "claude-sonnet-4-6" => 1_000_000,
    "claude-haiku-4-5" => 200_000,
    # Older Claude models
    "claude-3-5-sonnet-20241022" => 200_000,
    "claude-3-5-haiku-20241022" => 200_000,
    "claude-3-opus-20240229" => 200_000,
    # OpenAI
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
    "command-r" => 128_000,
    # Zhipu / z.ai GLM (OpenAI-compatible; the ollama_cloud route appends a
    # ":cloud" suffix to the model id, which the prefix match below strips —
    # e.g. "glm-5.2:cloud" starts_with "glm-5.2"). Windows are the vendor's
    # published maximums. GLM-5.2 ships a real 1M-token window (Ollama shows
    # "976K" only because it displays the count ÷1024); GLM-4.6 is 200K.
    "glm-5.2" => 1_000_000,
    "glm-5.1" => 200_000,
    "glm-5" => 200_000,
    "glm-4.6" => 200_000,
    "glm-4.5-air" => 128_000,
    "glm-4.5" => 128_000
  }

  @spec context_window(String.t()) :: pos_integer()
  def context_window(model) when is_binary(model) do
    case catalog_context_window(model) || Map.get(@fallback_context_windows, model) do
      nil ->
        # Try prefix match for Ollama models and variants
        matched =
          Enum.find(@fallback_context_windows, fn {key, _v} ->
            String.starts_with?(model, key)
          end)

        case matched do
          {_key, size} ->
            size

          nil ->
            # Check Ollama model info for num_ctx
            case get_ollama_context(model) do
              {:ok, ctx} -> ctx
              _ -> Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
            end
        end

      size ->
        size
    end
  end

  def context_window(_),
    do: Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

  @doc """
  The context window OSA will actually operate within for `model` on `provider`.

  For cloud providers this is just the trained / catalog window (`context_window/1`).
  For LOCAL providers (:ollama / :lmstudio / :llamacpp) it is capped to
  `:ollama_num_ctx` — the num_ctx ceiling OSA is willing to allocate (KV-cache
  memory scales with it). This is the single source of truth so that budgeting
  (Agent.Context) and the num_ctx we send to Ollama (Providers.Ollama.build_options)
  always agree, instead of Context believing it has a 32k-128k window while the
  Ollama server honors only 4096.

  A nil/non-binary `model` resolves through `context_window/1`'s catch-all to the
  config default (128k), preserving prior behavior for cloud providers.
  """
  @spec effective_context_window(String.t() | nil, atom()) :: pos_integer()
  def effective_context_window(model, provider) do
    trained = context_window(model)

    if provider in [:ollama, :lmstudio, :llamacpp] do
      ceiling = Application.get_env(:optimal_system_agent, :ollama_num_ctx, 32_768)
      min(trained, ceiling)
    else
      trained
    end
  end

  # Model ids for a provider from the Catalog, or nil when the Catalog has no
  # entry for it (so the caller falls back to the per-module list). Never raises.
  defp catalog_models_for(provider) do
    case OptimalSystemAgent.Providers.Catalog.models(provider) do
      [] -> nil
      models -> Enum.map(models, & &1.model_id)
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Catalog lookup (models.dev-style). Never raises: the Catalog reads a public
  # ETS table and returns nil when the table is absent or the model is unknown,
  # so callers cleanly fall through to the static table / Ollama probe.
  defp catalog_context_window(model) do
    OptimalSystemAgent.Providers.Catalog.context_window(model)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Sentinel cached for models whose context length could not be resolved from
  # Ollama (unreachable, non-200, or no context_length key). Caching the miss —
  # not just the hit — is a hot-path fix: context_window/1 runs on EVERY ReAct
  # iteration, so without a negative cache an unresolved model re-issued the 3s
  # /api/show POST every single iteration. The value it resolves to (the config
  # default) is unchanged; only the repeated blocking IO is eliminated. ETS is
  # cleared on restart, matching the "context_length doesn't change without a
  # re-pull" rationale of the positive cache.
  @no_ctx_sentinel :no_ctx

  defp get_ollama_context(model) do
    case cache_lookup(model) do
      {:ok, _ctx} = hit -> hit
      :negative -> :error
      :miss -> fetch_ollama_context(model)
    end
  end

  defp cache_lookup(model) do
    case :ets.whereis(:osa_context_cache) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(:osa_context_cache, model) do
          [{^model, @no_ctx_sentinel}] -> :negative
          [{^model, cached_ctx}] when is_integer(cached_ctx) -> {:ok, cached_ctx}
          _ -> :miss
        end
    end
  end

  defp cache_put(model, value) do
    case :ets.whereis(:osa_context_cache) do
      :undefined -> :ok
      _ -> :ets.insert(:osa_context_cache, {model, value})
    end
  end

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
          cache_put(model, ctx)
          {:ok, ctx}
        else
          cache_put(model, @no_ctx_sentinel)
          :error
        end

      _ ->
        cache_put(model, @no_ctx_sentinel)
        :error
    end
  rescue
    _ ->
      cache_put(model, @no_ctx_sentinel)
      :error
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

  # Ollama Cloud is configured when an OLLAMA_API_KEY is present OR a signed-in
  # local Ollama daemon can proxy :cloud models via device identity.
  def provider_configured?(:ollama_cloud) do
    case Application.get_env(:optimal_system_agent, :ollama_api_key) do
      key when is_binary(key) and key != "" -> true
      _ -> provider_configured?(:ollama)
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
