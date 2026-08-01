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
  alias OptimalSystemAgent.Providers.FallbackChain
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
  `true` when a same-provider error on the SYNC path (`chat/2`) warrants
  re-sending to the next provider in the fallback chain.

  Delegates to `FallbackChain.retryable_error?/1` — the single source of
  truth for this decision, shared with the streaming fallback path — so the
  sync path can never disagree with it again (finding #9 / #P4: this used to
  have NO gate at all and re-sent on every error, including context-overflow,
  missing/invalid API key, and model-not-found).
  """
  @spec should_fallback?(term()) :: boolean()
  def should_fallback?(reason), do: FallbackChain.retryable_error?(reason)

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
    opts = sanitize_tool_schemas(opts)
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
    opts = sanitize_tool_schemas(opts)
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
          emit_serving_provider(provider, opts)
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

  # The single provider-boundary sanitization point. Every provider module
  # (Anthropic, Google, Cohere, OpenAI-compatible, Ollama, …) reads
  # `opts[:tools]` and emits each tool's `:parameters` verbatim into its
  # request. Normalizing the schemas here — once, before dispatch/fallback —
  # guarantees no `anyOf`/`oneOf`/`additionalProperties: true`/raw `format`/
  # unbounded-integer/local-`$ref` construct ever reaches the wire, fixing the
  # google-antigravity `Type.Union` rejection regardless of which provider
  # serves the turn. Idempotent, so re-entry through the fallback chain is safe.
  defp sanitize_tool_schemas(opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        opts

      [] ->
        opts

      tools ->
        Keyword.put(
          opts,
          :tools,
          OptimalSystemAgent.Tools.SchemaNormalizer.normalize_tools(tools)
        )
    end
  end

  defp call_with_fallback(provider, module, messages, opts) do
    # Same-provider retry (backoff, retry-after aware) runs *before* any
    # model/provider fallback. Only once these retries are exhausted do we
    # drop to the configured fallback chain below.
    retried =
      Resilience.with_retry(
        fn ctx -> apply_provider(module, messages, merge_retry_ctx(opts, ctx)) end,
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

        # Only genuinely transient/overload errors warrant a cross-provider
        # re-send on the sync path. Context-overflow, missing/invalid API
        # key, auth, and model-not-found are NOT provider-specific — resending
        # to the next provider either fails identically (oversized prompt) or
        # silently answers from a different provider/model while masking the
        # real config error (finding #9 / #P4).
        if should_fallback?(reason) do
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
        else
          Logger.error(
            "Provider #{provider} failed with a non-retryable error, not falling back: #{inspect(reason)}"
          )

          err
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
          fn ctx -> native_stream(module, messages, callback, merge_retry_ctx(opts, ctx)) end,
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
                emit_serving_provider(fb_provider, opts)
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

    [on_retry: on_retry] ++ fail_fast_opts(provider)
  end

  # `:ollama` (the strictly-local daemon on localhost, NOT `:ollama_cloud`,
  # which proxies to ollama.com and can have real transient network issues)
  # gets a connection-refused fail-fast: retrying `econnrefused` against a
  # daemon that simply isn't running burns the full ~10-retry / ~200s backoff
  # budget before surfacing an error that then got its "Ollama" mention
  # stripped by ErrorCatalog anyway (P1). A connection refusal to localhost
  # will not fix itself between attempt 1 and attempt 2 either, so fail on
  # the first failure and let the actionable, Ollama-named message through
  # immediately. Every other Ollama error (timeout on a slow local
  # generation, a mid-download 500, …) keeps the normal retry budget.
  defp fail_fast_opts(:ollama), do: [fail_fast_categories: [:connection_error]]
  defp fail_fast_opts(_provider), do: []

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

  # Announce which provider/model actually served a turn after a fallback so the
  # TUI statusline can reflect the real serving provider instead of the one that
  # failed. Best-effort, mirroring emit_retry_event/2.
  defp emit_serving_provider(provider, opts) do
    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :"#{provider}_model")

    OptimalSystemAgent.Events.Bus.emit(:system_event, %{
      event: :provider_fallback,
      provider: provider,
      model: model
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

  # Fold the per-attempt retry context (from Resilience.with_retry's classifier)
  # into the provider opts so the request call-site can honor a header-aware
  # decision: `:force_http1` (HTTP/1.1 client rebuild to escape a poisoned
  # HTTP/2 pool on the first 5xx) and `:strip_images` (413 recovery).
  defp merge_retry_ctx(opts, ctx) when is_map(ctx) do
    opts
    |> Keyword.put(:force_http1, Map.get(ctx, :force_http1, false))
    |> Keyword.put(:strip_images, Map.get(ctx, :strip_images, false))
  end

  defp merge_retry_ctx(opts, _ctx), do: opts

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
    1. Ollama `/api/show` `model_info["<arch>.context_length"]` — FIRST for
       Ollama Cloud (`:cloud`) tags, because the daemon/ollama.com reports the
       model's REAL trained window and the static table below is only ever a
       hand-maintained guess (see `lookup_context_window/1`).
    2. `Providers.Catalog` (models.dev-style, refreshable source of truth)
    3. Static `@fallback_context_windows` table (offline safety net), exact key
       then family prefix
    4. Ollama `/api/show` (for everything else — local tags and unknown models)
    5. `:max_context_tokens` app env, then 128_000

  Step 5 is a FABRICATED number: it is not this model's window, it is a config
  default. Callers that render a percentage must not use it — use
  `context_window_info/1` / `effective_context_window_info/2`, which return
  `:unknown` instead of inventing a denominator (a wrong "% ctx" is worse than
  none). `context_window/1` keeps the lossy contract for existing callers that
  need a number (token budgeting, `num_ctx` sizing).

  The static table is retained only as a fallback for when the Catalog is
  unavailable (e.g. GenServer not started) or does not yet know a model.
  """
  @static_context_windows %{
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
    "glm-5.1" => 202_752,
    "glm-5" => 200_000,
    "glm-4.6" => 200_000,
    "glm-4.5-air" => 128_000,
    "glm-4.5" => 128_000,
    # Ollama model FAMILIES (bare, un-tagged names and local tags). The hosted
    # ":cloud" / "-cloud" tags are NOT listed here — they come from
    # `Providers.OllamaCloud`, the single source of truth, and are merged in
    # below as exact keys. Add a new cloud model THERE, not here.
    "nemotron-3-ultra" => 262_144,
    "nemotron-3-super" => 262_144,
    "minimax-m3" => 524_288,
    "deepseek-v4-pro" => 524_288,
    "deepseek-v4-flash" => 1_048_576,
    "kimi-k2.7-code" => 262_144,
    "kimi-k2.6" => 262_144,
    "qwen3.5" => 262_144,
    "gpt-oss:120b" => 131_072,
    "gpt-oss:20b" => 131_072,
    "gemma4" => 262_144
  }

  # Ollama Cloud tags override the family rows above: they are EXACT keys
  # ("gemma4:31b-cloud"), so `Map.get/2` finds them before the prefix scan ever
  # runs, and the same family's local tags keep their own row. These values are
  # only a FALLBACK — `lookup_context_window/1` probes /api/show first for cloud
  # tags, so the live window always wins when the daemon can answer.
  @fallback_context_windows Map.merge(
                              @static_context_windows,
                              OptimalSystemAgent.Providers.OllamaCloud.context_windows()
                            )

  @spec context_window(String.t()) :: pos_integer()
  def context_window(model) when is_binary(model) do
    case context_window_info(model) do
      {:ok, size} -> size
      :unknown -> default_context_window()
    end
  end

  def context_window(_), do: default_context_window()

  @doc """
  Like `context_window/1`, but HONEST: `{:ok, tokens}` only when the window is
  actually known (probed from Ollama, or listed by the Catalog / static table),
  and `:unknown` when it is not.

  `context_window/1` can never say "I don't know" — it returns the
  `:max_context_tokens` config default (128k) for any model nobody has heard of.
  For a token budget that is a survivable guess; for the TUI's "N% ctx" meter it
  is a lie: usage gets divided by a denominator that has nothing to do with the
  model, and the bar reads anywhere from wildly optimistic to wildly alarming.
  HTTP surfaces that feed the meter use this function and report tokens-used
  with NO percentage when it returns `:unknown`.
  """
  @spec context_window_info(String.t() | nil) :: {:ok, pos_integer()} | :unknown
  def context_window_info(model) when is_binary(model) do
    case lookup_context_window(model) do
      {:ok, size} -> {:ok, maybe_cap_1m_context(size, model)}
      :unknown -> :unknown
    end
  end

  def context_window_info(_), do: :unknown

  # Resolve the trained window WITHOUT ever inventing a number.
  #
  # Ollama Cloud (":cloud") models are probed FIRST. They are the case the
  # static table serves worst: they are not in models.dev, so they fall through
  # to a hand-maintained map or — worse — a family PREFIX guess
  # ("deepseek-v4-flash:cloud" matching the "deepseek-v4-flash" row), and any
  # model added by Ollama after the last edit of that map silently inherits the
  # 128k config default. Meanwhile /api/show reports the real
  # `<arch>.context_length` for cloud tags too: the local signed-in daemon
  # proxies the query, and when OLLAMA_URL points at https://ollama.com the
  # request goes there directly (with the API key). The probe is cached and
  # negative-cached, so this costs at most one short request per model per boot
  # and NEVER blocks a request path on a slow or failing probe — a miss simply
  # falls through to the previous static behaviour.
  defp lookup_context_window(model) do
    if ollama_cloud_model?(model) do
      case probe_context_window(model) do
        {:ok, _} = ok -> ok
        :unknown -> static_context_window(model)
      end
    else
      case static_context_window(model) do
        {:ok, _} = ok -> ok
        :unknown -> probe_context_window(model)
      end
    end
  end

  # Catalog → exact static entry → static family prefix. No probing, no default.
  defp static_context_window(model) do
    case catalog_context_window(model) || Map.get(@fallback_context_windows, model) do
      size when is_integer(size) and size > 0 ->
        {:ok, size}

      _ ->
        case Enum.find(@fallback_context_windows, fn {key, _v} ->
               String.starts_with?(model, key)
             end) do
          {_key, size} -> {:ok, size}
          nil -> :unknown
        end
    end
  end

  defp probe_context_window(model) do
    case get_ollama_context(model) do
      {:ok, ctx} when is_integer(ctx) and ctx > 0 -> {:ok, ctx}
      _ -> :unknown
    end
  end

  defp default_context_window,
    do: Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

  # Keep the advertised window in lockstep with the actually-sent request beta:
  # OSA only advertises Claude's 1M window when the context-1m beta will be sent
  # (Providers.Anthropic.supports_1m?/1). When the beta is disabled
  # (DISABLE_1M_CONTEXT / :disable_1m_context), a 1M-capable Claude model is
  # capped back to 200K so Agent.Context never budgets past what the API accepts
  # without the beta (the old bug: budget 1M, API 400 'prompt is too long').
  defp maybe_cap_1m_context(size, model) do
    m = String.downcase(to_string(model))

    if (String.contains?(m, "sonnet-4-6") or String.contains?(m, "opus-4-6")) and
         not Providers.Anthropic.supports_1m?(model) do
      min(size, 200_000)
    else
      size
    end
  end

  @doc """
  The context window OSA will actually operate within for `model` on `provider`.

  For cloud providers this is just the trained / catalog window (`context_window/1`).
  For LOCAL providers (:ollama / :lmstudio / :llamacpp) it is capped to
  `:ollama_num_ctx` — the num_ctx ceiling OSA is willing to allocate (KV-cache
  memory scales with it). This is the single source of truth so that budgeting
  (Agent.Context) and the num_ctx we send to Ollama (Providers.Ollama.build_options)
  always agree, instead of Context believing it has a 32k-128k window while the
  Ollama server honors only 4096.

  EXCEPTION — Ollama Cloud models (a ":cloud" tag, e.g. "glm-5.2:cloud"): even
  though they are served through the `:ollama` provider (the local daemon proxies
  them to Ollama's hosted hardware by device identity), they run REMOTELY and keep
  their full trained window. The local KV-cache `:ollama_num_ctx` ceiling does not
  apply, so they must NOT be capped — otherwise the context meter divides usage by
  the tiny local ceiling (e.g. 32k) instead of the real window (e.g. 1M), reading
  ~30x too high and filling almost instantly, and Agent.Context under-budgets the
  prompt. Detected via the same ":cloud" convention `provider_for_model/1` uses.

  A nil/non-binary `model` resolves through `context_window/1`'s catch-all to the
  config default (128k), preserving prior behavior for cloud providers.
  """
  @spec effective_context_window(String.t() | nil, atom()) :: pos_integer()
  def effective_context_window(model, provider) do
    model
    |> context_window()
    |> apply_local_ceiling(model, provider)
  end

  @doc """
  Honest variant of `effective_context_window/2`: `{:ok, tokens}` when the
  model's window is genuinely known, `:unknown` otherwise.

  Same provider-aware capping as `effective_context_window/2` — see
  `context_window_info/1` for why the "unknown" case exists at all.
  """
  @spec effective_context_window_info(String.t() | nil, atom() | nil) ::
          {:ok, pos_integer()} | :unknown
  def effective_context_window_info(model, provider) do
    case context_window_info(model) do
      {:ok, trained} -> {:ok, apply_local_ceiling(trained, model, provider)}
      :unknown -> :unknown
    end
  end

  @doc """
  `true` when the window used to render a context percentage is real (probed or
  catalogued) rather than the config fallback.

  With no provider it answers for the trained window; with a provider it answers
  for the effective (locally-capped) window.
  """
  @spec context_window_known?(String.t() | nil, atom() | nil) :: boolean()
  def context_window_known?(model, provider \\ nil)
  def context_window_known?(model, nil), do: match?({:ok, _}, context_window_info(model))

  def context_window_known?(model, provider),
    do: match?({:ok, _}, effective_context_window_info(model, provider))

  @doc """
  Drop any cached `/api/show` probe result for `model` so the next resolution
  re-probes.

  Called when the user SWITCHES model: the window must be re-resolved for the
  new tag, and a stale negative-cache entry (the daemon was down / not signed in
  the first time the model was seen) must not pin that model to the fabricated
  default for the rest of the session.
  """
  @spec forget_context_window(String.t() | nil) :: :ok
  def forget_context_window(model) when is_binary(model) do
    case :ets.whereis(:osa_context_cache) do
      :undefined -> :ok
      _ -> :ets.delete(:osa_context_cache, model)
    end

    :ok
  end

  def forget_context_window(_), do: :ok

  defp apply_local_ceiling(trained, model, provider) do
    if provider in [:ollama, :lmstudio, :llamacpp] and not ollama_cloud_model?(model) do
      ceiling = Application.get_env(:optimal_system_agent, :ollama_num_ctx, 32_768)

      # Floor against the model's REAL trained window too, not just the config
      # ceiling. A static/catalog entry (or a family prefix match) can advertise
      # a larger window than the specific local tag actually supports (e.g. an
      # 8k-context local model whose family lists 128k). For :ollama we consult
      # the live /api/show num_ctx (negative-cached) so num_ctx never exceeds the
      # weights' real context_length. Result: min(config ceiling, trained window).
      trained
      |> min(local_trained_window(provider, model, trained))
      |> min(ceiling)
    else
      trained
    end
  end

  # Real trained window for a LOCAL model. For :ollama we probe /api/show
  # (cached, incl. a negative cache) and fall back to `default` when the server
  # is unreachable or does not report a context length. Non-:ollama local
  # providers (lmstudio/llamacpp) have no Ollama /api/show endpoint, so they keep
  # the resolved `default`.
  defp local_trained_window(:ollama, model, default) when is_binary(model) do
    case get_ollama_context(model) do
      {:ok, ctx} when is_integer(ctx) and ctx > 0 -> ctx
      _ -> default
    end
  end

  defp local_trained_window(_provider, _model, default), do: default

  # True for an Ollama Cloud model. These are proxied to Ollama's hosted
  # hardware and keep their full trained window, so `effective_context_window/2`
  # must not squeeze them under the local KV-cache num_ctx ceiling. Delegated to
  # the OllamaCloud catalog so BOTH hosted tag shapes count — ":cloud" and the
  # size-qualified "-cloud" ("gpt-oss:120b-cloud") — and so this and
  # `provider_for_model/1` can never drift apart again.
  defp ollama_cloud_model?(model),
    do: OptimalSystemAgent.Providers.OllamaCloud.cloud_tag?(model)

  @doc """
  Resolve the provider atom that OWNS `model`.

  Uses the Catalog (models.dev provider_id) first, then a name heuristic, and
  finally nil when the model can't be attributed. Only ever returns a provider
  that is actually registered here. Powers the cross-provider CLI `/model` switch
  so `/model claude-sonnet-4-6` routes to :anthropic even when the default
  provider is :ollama.
  """
  @spec provider_for_model(String.t()) :: atom() | nil
  def provider_for_model(model) when is_binary(model) do
    catalog_provider_for(model) || heuristic_provider_for(model)
  end

  def provider_for_model(_), do: nil

  defp catalog_provider_for(model) do
    with %{provider_id: pid} when is_binary(pid) <- safe_catalog_find(model),
         atom when is_atom(atom) <- provider_id_to_atom(pid),
         true <- Map.has_key?(@providers, atom) do
      atom
    else
      _ -> nil
    end
  end

  defp safe_catalog_find(model) do
    OptimalSystemAgent.Providers.Catalog.find(model)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # models.dev provider ids mostly match OSA atoms; map the few that differ.
  defp provider_id_to_atom(pid) do
    case pid do
      "x-ai" ->
        :xai

      "google-vertex" ->
        :google

      "azure" ->
        :openai

      _ ->
        try do
          String.to_existing_atom(pid)
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp heuristic_provider_for(model) do
    m = String.downcase(model)

    cond do
      # FIRST — before any vendor-name prefix. A hosted tag belongs to Ollama
      # Cloud no matter what it is named; without this ordering
      # "gpt-oss:120b-cloud" fell through to the starts_with?("gpt") branch and
      # was routed to :openai.
      OptimalSystemAgent.Providers.OllamaCloud.cloud_tag?(m) ->
        :ollama_cloud

      String.starts_with?(m, "claude") ->
        :anthropic

      String.starts_with?(m, "gpt") ->
        :openai

      String.starts_with?(m, "o1") or String.starts_with?(m, "o3") or
          String.starts_with?(m, "o4") ->
        :openai

      String.starts_with?(m, "gemini") ->
        :google

      String.starts_with?(m, "deepseek") ->
        :deepseek

      String.starts_with?(m, "grok") ->
        :xai

      String.starts_with?(m, "command") ->
        :cohere

      String.starts_with?(m, "mistral") or String.starts_with?(m, "mixtral") ->
        :mistral

      String.starts_with?(m, "glm") ->
        :zhipu

      String.starts_with?(m, "qwen") ->
        :qwen

      String.starts_with?(m, "moonshot") or String.starts_with?(m, "kimi") ->
        :moonshot

      String.starts_with?(m, "llama") ->
        :groq

      true ->
        nil
    end
  end

  @doc """
  True when `model` is a plausible model for `provider`.

  Local providers accept any tag (models are pulled dynamically). For cloud
  providers, a model is accepted when the Catalog knows it (for the provider or
  anywhere), OR when the Catalog has NO data for that provider at all (offline /
  not-yet-loaded — be permissive rather than block a valid switch). Only when the
  Catalog positively knows the provider AND the model is absent do we reject.
  """
  @spec known_model?(atom(), String.t()) :: boolean()
  def known_model?(provider, model) when is_atom(provider) and is_binary(model) do
    cond do
      provider in [:ollama, :ollama_cloud, :lmstudio, :llamacpp] -> true
      catalog_model_known?(provider, model) -> true
      true -> not catalog_has_provider?(provider)
    end
  end

  def known_model?(_provider, _model), do: false

  defp catalog_model_known?(provider, model) do
    (safe_catalog_model(provider, model) || safe_catalog_find(model)) != nil
  end

  defp safe_catalog_model(provider, model) do
    OptimalSystemAgent.Providers.Catalog.model(to_string(provider), model)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp catalog_has_provider?(provider) do
    OptimalSystemAgent.Providers.Catalog.models(to_string(provider)) != []
  rescue
    _ -> false
  catch
    _, _ -> false
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

  # A TRANSPORT failure is not an answer. Ollama being unreachable, slow, or
  # unauthenticated at the moment of the probe says nothing about the model's
  # context length — and since the honest lookups now report `:unknown` (rather
  # than falling back to the 128k default), a permanently cached transport
  # failure pins the model's window to 0 FOR THE LIFE OF THE BEAM. That is what
  # made the context meter read a flat 0% forever: the TUI starts before/faster
  # than the daemon is ready, the very first probe fails, and the model can
  # never be resolved again no matter how healthy Ollama becomes.
  #
  # So the two negative outcomes are cached differently:
  #   * definitive  — a 200 response that simply carries no `context_length`
  #     key. The daemon answered; the answer will not change. Cached forever
  #     (`@no_ctx_sentinel`).
  #   * transient   — unreachable / non-200 / timeout / raised. Cached only for
  #     `@negative_ttl_ms`, so the hot path stays IO-free (at most one probe per
  #     model per TTL, versus one per ReAct iteration, which is what the
  #     negative cache existed to prevent) while a daemon that comes up later
  #     still gets a chance to answer.
  @negative_ttl_ms 60_000

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
          [{^model, @no_ctx_sentinel}] ->
            :negative

          # Transient failure: honour the negative cache only until it expires,
          # then fall through to :miss so the model is probed again.
          [{^model, {@no_ctx_sentinel, expires_at}}] ->
            if System.monotonic_time(:millisecond) < expires_at, do: :negative, else: :miss

          [{^model, cached_ctx}] when is_integer(cached_ctx) ->
            {:ok, cached_ctx}

          _ ->
            :miss
        end
    end
  end

  # Cache a transient probe failure with an expiry so it can be retried.
  defp cache_put_transient(model) do
    cache_put(model, {@no_ctx_sentinel, System.monotonic_time(:millisecond) + @negative_ttl_ms})
  end

  defp cache_put(model, value) do
    case :ets.whereis(:osa_context_cache) do
      :undefined -> :ok
      _ -> :ets.insert(:osa_context_cache, {model, value})
    end
  end

  # Best-effort probe. Short timeout, no retries, every failure mode collapses
  # to :error, so a slow or broken Ollama can never stall a request path — the
  # caller just falls back to the static table / config default.
  #
  # The failure is cached PERMANENTLY only when the daemon actually answered and
  # the answer contained no context length (a definitive "this model does not
  # report one"). Transport failures get a short TTL instead — see
  # `@negative_ttl_ms`. Conflating the two is what let a single failed probe at
  # startup pin a model's window to "unknown" forever.
  @probe_timeout_ms 3_000

  defp fetch_ollama_context(model) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    opts =
      [json: %{name: model}, receive_timeout: @probe_timeout_ms, retry: false] ++
        probe_auth_headers()

    case Req.post("#{url}/api/show", opts) do
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
          # Definitive: the daemon answered and reports no context length.
          cache_put(model, @no_ctx_sentinel)
          :error
        end

      # Transport failure (unreachable / non-200 / timeout) — retryable.
      _ ->
        cache_put_transient(model)
        :error
    end
  rescue
    _ ->
      cache_put_transient(model)
      :error
  end

  # Ollama Cloud's own host (OLLAMA_URL=https://ollama.com) requires the API key
  # on /api/show; a local daemon ignores the header. Harmless either way.
  defp probe_auth_headers do
    case Application.get_env(:optimal_system_agent, :ollama_api_key) do
      key when is_binary(key) and key != "" ->
        [headers: [{"authorization", "Bearer #{key}"}]]

      _ ->
        []
    end
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
      _ -> live_cloud_key_present?(:ollama_cloud) or provider_configured?(:ollama)
    end
  end

  # Boot-time `Application.get_env` is a one-shot snapshot taken when
  # `config/runtime.exs` ran. A key added to `~/.osa/.env` afterward by a
  # different OS process (the CLI setup wizard, `osa setup`, a hand edit)
  # never reaches it, so a lone cloud key can report "not configured" even
  # though it plainly is (P2/P3). Fall back to a live re-read before saying no.
  def provider_configured?(provider) do
    key = :"#{provider}_api_key"

    case Application.get_env(:optimal_system_agent, key) do
      nil -> live_cloud_key_present?(provider)
      "" -> live_cloud_key_present?(provider)
      _ -> true
    end
  end

  # Local/keyless providers are excluded from live key checks and from the
  # "did the user configure exactly one cloud provider" default-provider
  # heuristic below — Ollama's own reachability probe already covers it, and
  # checking it here would mean a network round-trip on every chat call.
  @keyless_providers [:ollama, :ollama_cloud, :lmstudio, :llamacpp, :mock]

  defp live_cloud_key_present?(provider) do
    env_var = provider |> Atom.to_string() |> String.upcase() |> Kernel.<>("_API_KEY")

    case OptimalSystemAgent.Onboarding.live_env(env_var) do
      v when is_binary(v) and v != "" -> true
      _ -> false
    end
  end

  # Provider selected for the next turn when the caller didn't ask for a
  # specific one. Order of precedence:
  #
  #   1. An explicit `OSA_DEFAULT_PROVIDER`, read LIVE (System env, then a
  #      fresh re-parse of `~/.osa/.env`) — not just the boot-time snapshot —
  #      so a value written after this node started is honored without a
  #      restart (F1/P2).
  #   2. If nothing explicit is set and the boot-time snapshot fell back to
  #      the `:ollama` default (i.e. no key was configured at boot time),
  #      but exactly ONE cloud provider now has a live key, prefer that
  #      provider over silently routing to a possibly-absent local Ollama
  #      (P2: "a lone cloud key is invisible unless it was the boot
  #      default").
  #   3. Otherwise, the boot-time snapshot (`config/runtime.exs`'s own
  #      detection, e.g. an explicit choice or MIOSA_API_KEY/OLLAMA_API_KEY
  #      priority order) — unchanged behavior.
  @doc false
  # Test/introspection seam for `default_provider/0` (private so `chat/2`
  # can't be called with a bogus provider from outside, but the resolution
  # logic itself — live explicit override / lone-live-key heuristic / boot
  # snapshot — is exercised directly in tests without a real network call).
  @spec resolved_default_provider() :: atom()
  def resolved_default_provider, do: default_provider()

  defp default_provider do
    case live_explicit_default_provider() do
      {:ok, provider} ->
        provider

      :error ->
        boot_default = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

        if boot_default == :ollama do
          case lone_live_cloud_provider() do
            {:ok, provider} -> provider
            :error -> boot_default
          end
        else
          boot_default
        end
    end
  end

  defp live_explicit_default_provider do
    case OptimalSystemAgent.Onboarding.live_env("OSA_DEFAULT_PROVIDER") do
      nil ->
        :error

      value ->
        try do
          atom = value |> String.trim() |> String.downcase() |> String.to_existing_atom()
          if Map.has_key?(@providers, atom), do: {:ok, atom}, else: :error
        rescue
          ArgumentError -> :error
        end
    end
  end

  defp lone_live_cloud_provider do
    configured =
      @providers
      |> Map.keys()
      |> Enum.reject(&(&1 in @keyless_providers))
      |> Enum.filter(&live_cloud_key_present?/1)

    case configured do
      [provider] -> {:ok, provider}
      _ -> :error
    end
  end
end
