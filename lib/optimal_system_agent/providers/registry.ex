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
  alias OptimalSystemAgent.Providers.ImageBudget
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

                 # ChatGPT Plus/Pro plan over the Responses API. A SEPARATE
                 # entry from :openai, not a second auth mode on it — different
                 # base URL, different wire protocol, different model catalogue.
                 openai_codex: Providers.OpenAICodex,

                 # Claude Pro/Max plan, driven through Anthropic's own Claude
                 # Code CLI as a subprocess — the one third-party path
                 # Anthropic sanctions. A SEPARATE entry from :anthropic, for
                 # the same reason codex is separate from :openai: the
                 # transport is not the API at all.
                 claude_cli: Providers.ClaudeCli,

                 # GitHub Copilot plan, driven through GitHub's own Copilot
                 # CLI. Separate from any Copilot API path for the same
                 # reason as the two above: the transport is a subprocess.
                 copilot_cli: Providers.CopilotCli,

                 # Amazon Bedrock over the Converse API, signed with SigV4
                 # against the operator's own AWS account. Not OpenAI-
                 # compatible and not an API-key provider in the usual sense:
                 # the credential is the AWS chain (or a Bedrock bearer key),
                 # resolved live per request.
                 bedrock: Providers.Bedrock,

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
                 uncensored: {:compat, :uncensored},
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

  @compat_providers @providers
                    |> Enum.filter(&match?({_, {:compat, _}}, &1))
                    |> Enum.map(&elem(&1, 0))
                    |> Enum.sort()

  @doc """
  Every provider whose requests are assembled by `Providers.OpenAICompat`.

  Derived from `@providers` at compile time rather than restated, so a provider
  added to the registry cannot be missed by a consumer that needs to know which
  request-shaping seam applies to it. `Observability.current_reasoning/1` is
  that consumer: `OpenAICompat.reasoning_decision/2` is the only authority on
  whether these requests carry `reasoning_effort`, and asking it of a provider
  that does not use this transport (`:claude_cli`, `:openai_codex`, `:cohere`,
  …) would report a decision nothing ever made.
  """
  @spec compat_providers() :: list(atom())
  def compat_providers, do: @compat_providers

  @doc "True when `provider`'s requests are built by `Providers.OpenAICompat`."
  @spec compat_routed?(atom()) :: boolean()
  def compat_routed?(provider), do: provider in @compat_providers

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
  Does `provider` carry tool schemas over a native tool channel?

  Resolves the provider atom to the module that will actually build the request
  (including the `{:compat, _}` indirection and any runtime-registered provider)
  and asks it via the optional `native_tool_schemas?/0` callback.

  Defaults to `false` for anything that does not export the callback — including
  runtime-registered providers, which live in GenServer state this function
  deliberately does not call into. That default is the safe one: it is what
  keeps the full prose tool documentation in the system prompt for transports
  that have nowhere else to put it. Two routed providers really are in that
  position — `claude_cli` and `copilot_cli` drive a CLI subprocess and fold the
  tool list into `build_system_prompt/2`, i.e. into prompt TEXT — so this is a
  live distinction, not a hypothetical.
  """
  @spec native_tool_schemas?(atom()) :: boolean()
  def native_tool_schemas?(provider) when is_atom(provider) do
    case Map.get(@providers, provider) do
      nil -> false
      {:compat, _} -> module_declares_native_tools?(@compat)
      mod when is_atom(mod) -> module_declares_native_tools?(mod)
    end
  end

  def native_tool_schemas?(_), do: false

  defp module_declares_native_tools?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :native_tool_schemas?, 0) and
      module.native_tool_schemas?() == true
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

  # Same one-way door `stream_with_fallback/5` enforces, applied at the OTHER
  # entrance. `fallback_sync_stream/4` pushes the WHOLE sync response through
  # the live callback as a single `:text_delta` — there is no `emitted` cursor,
  # so if the provider had already streamed part of the answer the user sees
  # that prefix twice and the duplicate is what gets appended as the assistant
  # turn and persisted. The top-level path checks `output_observed?/0` before
  # calling this; the per-hop path in `do_try_stream_provider/4` did not, so a
  # fallback-chain hop that died mid-stream re-emitted everything.
  defp fallback_sync_stream_unless_observed(module, messages, callback, opts, reason) do
    if Resilience.output_observed?() do
      Logger.warning(
        "Provider #{inspect(module)} stream failed after output was already streamed to the " <>
          "user — not retrying via sync (it would duplicate what is on screen): " <>
          Resilience.reason_to_string(reason)
      )

      {:error, reason}
    else
      fallback_sync_stream(module, messages, callback, opts)
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

    # Every provider reached through this function is a hop AWAY from the one
    # the turn resolved its model for — both callers (`try_fallback_chain/4` and
    # the `should_fallback?` branch of `chat/2`) pass a chain with the failed
    # provider already dropped. Carrying `opts[:model]` here asks each of them
    # for a tag only the original provider serves.
    hop_opts = cross_provider_opts(opts)

    Enum.reduce_while(available_chain, {:error, "No providers in chain"}, fn provider, _acc ->
      case chat(messages, Keyword.put(hop_opts, :provider, provider)) do
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

  # Opts for a hop to a DIFFERENT provider than the one the turn resolved.
  #
  # `opts[:model]` is resolved for the provider that just failed. Forwarding it
  # asked Ollama for `claude-sonnet-5` — a tag its daemon has never heard of — so
  # every Ollama fallback failed for a reason that had nothing to do with the
  # actual fault, and that bogus error is the one the chain reported. Dropping the
  # key lets each provider resolve its own configured default (`OLLAMA_MODEL`,
  # `OPENAI_MODEL`, …), which is the only model it can actually serve.
  #
  # Public because the same hop happens in `FallbackChain`, which drives the
  # chain the agent loop actually uses. Applying this at only one of the hop
  # sites fixes the symptom on one path and leaves it on the others.
  @doc false
  @spec cross_provider_opts(keyword()) :: keyword()
  def cross_provider_opts(opts), do: Keyword.drop(opts, [:model])

  # ── Outbound message normalization (the second provider boundary) ─────────
  #
  # Everything a provider module reads off a MESSAGE gets normalized here, once,
  # before dispatch/fallback: structured `content` blocks (below) and tool-call
  # `arguments` (further below). Both are idempotent, so re-entry through a retry
  # or a fallback hop is free.
  @doc false
  @spec normalize_outbound_messages(list(), module() | {:compat, atom()}, keyword()) :: list()
  def normalize_outbound_messages(messages, target, opts \\ [])

  def normalize_outbound_messages(messages, target, opts) when is_list(messages) do
    messages
    # FIRST: every step below reads or rebuilds these binaries, and the encoder
    # at the end of the pipe raises on an undecodable byte. See
    # `Utils.WireEncoding` — a `file_grep` hit on one latin-1 line used to kill
    # the turn with `Jason.EncodeError: invalid byte 0xDA`, rescued into
    # `{:error, "Provider error: …"}` and scored against the model.
    |> OptimalSystemAgent.Utils.WireEncoding.scrub_messages()
    |> normalize_tool_call_arguments()
    |> normalize_message_content(target, opts)
    # Anti-flagging: inject platform authorization annotation into the last
    # user message when the content is security-related. This makes the
    # provider less likely to flag pentest requests. See
    # `Providers.PlatformAuthorization` and `Providers.Moderation`.
    |> maybe_inject_authorization(opts)
    # LAST: it reads the `cache_control` blocks the step above preserves, and
    # appends a trailing message, so it must see the final message list.
    |> Providers.PromptCache.restructure(target, opts)
  end

  def normalize_outbound_messages(messages, _target, _opts), do: messages

  # ── Tool-call argument normalization ──────────────────────────────────────
  #
  # A tool call's `arguments` must be an OBJECT by the time it reaches any wire.
  # Providers emit it verbatim — Anthropic as `tool_use.input`, Ollama/Google as
  # a nested map, the OpenAI-compatible providers as a JSON encoding OF it — and
  # every one of them rejects a bare string:
  #
  #     anthropic → 400 messages.N.content.M.tool_use.input: Input should be an object
  #     ollama    → 400 {"error":"Value looks like object, but can't find closing '}' symbol"}
  #
  # `Agent.Compactor` used to strip heavy arguments to the STRING
  # `"[args stripped]"`, and compacted history is PERSISTED. That made the damage
  # permanent and provider-independent: the primary provider 400'd, then every
  # provider in the fallback chain 400'd on the same message, so the only error
  # the user ever saw was the last hop's — an Ollama parse error on a session
  # configured for Anthropic, unfixable by switching models.
  #
  # ── Anti-flagging: platform authorization injection ───────────────────────
  #
  # When the user's message is security-related, inject a hidden authorization
  # annotation into the last user message at the provider boundary. This makes
  # the LLM provider less likely to flag pentest requests as unauthorized.
  #
  # Detection: if the moderation API key is configured, use the moderation
  # pre-screen. Otherwise, fall back to keyword detection.
  # The annotation is stripped from all previous messages before adding a new
  # one, so it never accumulates across turns.
  @doc false
  @spec maybe_inject_authorization(list(), keyword()) :: list()
  def maybe_inject_authorization(messages, _opts) when not is_list(messages), do: messages

  def maybe_inject_authorization(messages, opts) do
    # Skip if explicitly disabled
    if Keyword.get(opts, :skip_authorization, false) do
      messages
    else
      authorized = determine_authorization(messages, opts)
      Providers.PlatformAuthorization.annotate(messages, authorized)
    end
  rescue
    _ -> messages
  catch
    _, _ -> messages
  end

  defp determine_authorization(messages, _opts) do
    # Layer 1 of the anti-flagging system is the operator explicitly arming it
    # (/jailbreak block). The annotation is layer 2 — it must never fire on a
    # stock session: keyword hits alone (a security-adjacent conversation, or
    # tool output that merely contains words like "injection" or "scan") are
    # NOT authorization to forge an "I am authorized" sentence into the
    # operator's own message.
    if OptimalSystemAgent.Agent.Jailbreak.active?() do
      # If OpenAI moderation API key is configured, use the moderation pre-screen.
      # Otherwise, fall back to keyword-based detection.
      api_key = Application.get_env(:optimal_system_agent, :openai_api_key)

      if is_binary(api_key) and api_key != "" do
        result = Providers.Moderation.check_messages(messages, api_key: api_key)
        result.should_uncensor
      else
        Providers.Moderation.should_annotate?(messages)
      end
    else
      false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # The Compactor no longer writes it, but sessions already on disk still carry
  # it, so the coercion belongs HERE as well as at the source: history is loaded,
  # not rebuilt, and a session recorded before the fix must not stay bricked.
  # This is also the natural home for the inverse case — an OpenAI-shaped
  # provider that reported `arguments` as a JSON-encoded object string.
  @doc false
  @spec normalize_tool_call_arguments(list()) :: list()
  def normalize_tool_call_arguments(messages) when is_list(messages) do
    # Cheap guard: valid arguments are the overwhelmingly common case, and a
    # retry loop re-enters here on every attempt. Only rebuild when needed.
    if Enum.any?(messages, &invalid_tool_args?/1) do
      Enum.map(messages, &coerce_message_tool_args/1)
    else
      messages
    end
  end

  def normalize_tool_call_arguments(messages), do: messages

  defp invalid_tool_args?(msg) when is_map(msg) do
    case Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") do
      calls when is_list(calls) ->
        Enum.any?(calls, fn
          tc when is_map(tc) -> not is_map(tc[:arguments] || tc["arguments"])
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp invalid_tool_args?(_msg), do: false

  defp coerce_message_tool_args(msg) when is_map(msg) do
    cond do
      is_list(Map.get(msg, :tool_calls)) ->
        Map.put(msg, :tool_calls, Enum.map(Map.get(msg, :tool_calls), &coerce_tool_call_args/1))

      is_list(Map.get(msg, "tool_calls")) ->
        Map.put(msg, "tool_calls", Enum.map(Map.get(msg, "tool_calls"), &coerce_tool_call_args/1))

      true ->
        msg
    end
  end

  defp coerce_message_tool_args(msg), do: msg

  # Write back under the key shape the call already uses, for the same reason the
  # Compactor does: a rehydrated call from a persisted session is string-keyed,
  # and an atom `:arguments` added beside its `"arguments"` would leave the
  # invalid value still sitting on the wire under the string key.
  #
  # The early-return must test the SAME key `invalid_tool_args?/1` judged, which
  # is `tc[:arguments] || tc["arguments"]` — atom first. A call carrying a bad
  # atom `:arguments` beside a good string `"arguments"` is flagged invalid, and
  # returning it unchanged because the string side happens to be a map would
  # leave the bad atom value on the wire: Anthropic and Google read the atom key
  # first too, so it is the one that would be serialized.
  defp coerce_tool_call_args(tc) when is_map(tc) do
    cond do
      is_map(Map.get(tc, :arguments)) ->
        tc

      is_map(Map.get(tc, "arguments")) and not Map.has_key?(tc, :arguments) ->
        tc

      Map.has_key?(tc, "arguments") and not Map.has_key?(tc, :arguments) ->
        Map.put(tc, "arguments", decode_tool_args(Map.get(tc, "arguments")))

      true ->
        Map.put(tc, :arguments, decode_tool_args(Map.get(tc, :arguments)))
    end
  end

  defp coerce_tool_call_args(tc), do: tc

  # A JSON-encoded object is recovered rather than discarded — that is a real
  # OpenAI-shaped wire value and the call's inputs are still in there. Anything
  # else (the old `"[args stripped]"` placeholder, a stream truncated mid-object,
  # a JSON array or scalar, `nil`) becomes the empty object.
  defp decode_tool_args(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_raw), do: %{}

  # ── Structured-content normalization ──────────────────────────────────────
  #
  # The sibling of `sanitize_tool_schemas/1` above, for message CONTENT.
  #
  # Anthropic is the only provider OSA talks to whose `content` field accepts an
  # array of typed blocks. Every other provider module does `to_string(content)`
  # somewhere in its `format_messages/1` (`openai_compat.ex`, `ollama.ex`,
  # `cohere.ex`, `replicate.ex`) or its `extract_system/1` (`google.ex`), and a
  # list has no `String.Chars` implementation — so a block list reaching any of
  # them raises `ArgumentError: cannot convert the given list to a string`.
  #
  # That was survivable only while block-shaped content was rare. Two callers
  # now produce it on the normal path:
  #
  #   * `Agent.Context.build_system_message/4` emits the system prompt as three
  #     `cache_control`-marked blocks whenever the provider is `:anthropic` —
  #     the prompt-cache fix, without which the hit rate is a hard 0%.
  #   * `MessageHandler.build_messages/3` and `ToolExecutor` emit `user`/`tool`
  #     turns as `text` + `image` blocks whenever an image is attached.
  #
  # And `Loop.LLMClient` hands `FallbackChain` the SAME already-built messages
  # without rebuilding context for the new provider. So an Anthropic 5xx used to
  # fail over into a guaranteed `ArgumentError` on every remaining provider,
  # each one swallowed by `FallbackChain`'s `rescue` and reported as
  # `{:error, "All providers failed: …"}` — the fallback path was dead exactly
  # when it was needed.
  #
  # WHY HERE, and not by rebuilding context per-provider in `FallbackChain`:
  # rebuilding is the more principled fix (a fallback to Ollama would get a
  # prompt sized for Ollama's window), but it needs the full agent state threaded
  # down into the provider layer, it only fixes the one caller, and it leaves
  # every direct `Registry.chat/2` caller — subagents, the compactor, the goal
  # verifier, `chat_with_fallback/3` — still holding the crash. Normalizing at
  # dispatch fixes all of them at once, is idempotent (so re-entry through a
  # retry or a fallback hop is free), and touches nothing in the loop. The
  # rebuild remains worth doing on its own merits; it is not what unbreaks this.
  #
  # Normalization is keyed on the DISPATCH TARGET, not on the requested
  # provider, so it is decided by who is actually about to receive the bytes.
  #
  # ## The image carve-out
  #
  # Flattening EVERY structured block was right while Anthropic was the only
  # provider that could read one. It is not right any more: `OpenAICompat`,
  # `Google` and `Bedrock` now encode native image parts, and flattening ahead
  # of them made those encoders unreachable — and told the user a provider
  # "does not accept inline image content" when in fact gpt-4o, Gemini and
  # Claude-on-Bedrock all do.
  #
  # An image block is now passed through UNTOUCHED when both are true:
  #
  #   1. **The transport can carry it.** Asked of the dispatch target itself
  #      (`supports_image_content?/0`), so the answer lives next to the encoder
  #      rather than in a provider allowlist here that drifts out of date.
  #      `Ollama`, `Cohere` and `Replicate` do not export it, so they keep the
  #      old flattening — without it they raise on a list.
  #   2. **The model is not known to be text-only.** Asked of
  #      `ImageBudget.vision_capable?/2`, the same `Catalog`-backed predicate
  #      the providers' own `gate_unsupported/3` uses. One source of truth.
  #
  # An UNKNOWN model (not in the catalog, or a fallback hop where
  # `cross_provider_opts/1` has dropped `:model`) is passed THROUGH, not
  # flattened. Both choices are conservative in a different direction; this one
  # is chosen because flattening an unknown model is silent and permanent — a
  # newly released vision model would quietly never receive images, and the
  # placeholder would assert a falsehood about why — whereas passing through
  # fails loudly at the provider with a message naming the real limitation. It
  # is also the same call `ImageBudget.gate_unsupported/3` already makes, so
  # "unknown" means the same thing at both layers.
  #
  # Text-only structured content is UNAFFECTED: only a block list that actually
  # contains an image block can take the carve-out, so a system prompt split
  # into `cache_control` blocks still flattens byte-identically to the string
  # every non-Anthropic provider received before.
  @doc false
  @spec normalize_message_content(list(), module() | {:compat, atom()}) :: list()
  def normalize_message_content(messages, target),
    do: normalize_message_content(messages, target, [])

  @doc false
  @spec normalize_message_content(list(), module() | {:compat, atom()}, keyword()) :: list()
  def normalize_message_content(messages, Providers.Anthropic, _opts), do: messages

  def normalize_message_content(messages, target, opts) when is_list(messages) do
    # Cheap guard: the overwhelmingly common case is all-string content, and a
    # retry loop re-enters here on every attempt. Only rebuild when there is
    # something to rebuild.
    if Enum.any?(messages, &structured_content?/1) do
      carry_images? = carry_images?(target, opts)
      reason = if carry_images?, do: nil, else: omission_reason(target)

      # The cache carve-out, exactly parallel to the image one above it. A
      # `cache_control`-marked block list is the prompt-cache fix; flattening it
      # to a string here is what silently deleted every breakpoint on the
      # OpenRouter path and pinned the hit rate at 0%. `OpenAICompat` encodes
      # these as OpenAI text content-parts with the marker preserved, which
      # OpenRouter forwards to Anthropic.
      # Two questions, deliberately separate. `anthropic_prompt_cache?/2` is a
      # CAPABILITY question — does this wire forward the field — and stays a
      # pure fact about the route. `PromptCache.enabled?/0` is the global POLICY
      # switch. Flattening the blocks here is what deletes every breakpoint the
      # system-prompt builder placed, so this is the point on the compat path
      # where the kill switch has to bite; without it, setting the flag false
      # disabled caching on native Anthropic and left OpenRouter → Anthropic
      # fully cached.
      keep_cache? =
        Providers.PromptCache.enabled?() and
          anthropic_prompt_cache?(target, resolved_model(target, opts))

      flattened =
        Enum.map(messages, &flatten_message_content(&1, carry_images?, keep_cache?, reason))

      # A user attached an image and we destroyed it. Until now the ONLY trace of
      # that was the replacement sentence sitting inside the prompt — visible to
      # the model, invisible to the operator, and absent from every log and
      # metric. `Ollama.apply_tools/3` already emits `[:osa, :ollama,
      # :tools_stripped]` for exactly this reason ("a capability silently removed
      # must never be a decision someone has to go looking for"); the image gate
      # gets the same treatment. Counted from the INPUT, because by now the
      # blocks are gone.
      unless carry_images? do
        report_dropped_images(count_image_blocks(messages), target, reason, opts)
      end

      flattened
    else
      messages
    end
  end

  def normalize_message_content(messages, _target, _opts), do: messages

  # Zero is the ordinary case (structured content is usually cache markers or
  # plain text parts, not images) and must stay silent — an "0 images dropped"
  # line on every turn is noise, and noise is its own kind of invisible.
  defp report_dropped_images(0, _target, _reason, _opts), do: :ok

  defp report_dropped_images(n, target, reason, opts) do
    provider = provider_key(target)
    model = Keyword.get(opts, :model)

    Logger.warning(
      "[registry] #{n} image(s) not sent to #{provider}/#{model || "?"}: " <>
        case reason do
          :transport -> "OSA's integration for this provider cannot carry images"
          :model -> "the model does not accept image input"
          _ -> "images are not carried on this route"
        end
    )

    :telemetry.execute(
      [:osa, :images, :dropped],
      %{count: n},
      %{provider: provider, model: model, reason: reason}
    )
  rescue
    _ -> :ok
  end

  defp count_image_blocks(messages) do
    Enum.reduce(messages, 0, fn
      %{content: blocks}, acc when is_list(blocks) ->
        acc + Enum.count(blocks, &image_block?/1)

      %{"content" => blocks}, acc when is_list(blocks) ->
        acc + Enum.count(blocks, &image_block?/1)

      _, acc ->
        acc
    end)
  end

  # Can this dispatch target put an image on the wire at all, for this model?
  defp carry_images?(target, opts) do
    transport_carries_images?(target) and
      ImageBudget.vision_capable?(provider_key(target), Keyword.get(opts, :model))
  end

  @doc """
  Does this (provider, model) pair honour Anthropic-style `cache_control`
  breakpoints on the wire?

  MEASURED, not assumed. Against a live OpenRouter key on 2026-08-14, the same
  12.4k-token system prefix sent twice:

      cache_control present → cache_write 12,408 then cache_read 12,408, and
                              the second request cost $0.00127
      cache_control absent  → cached_tokens 0 on both, $0.01244 each

  A 9.8x difference on identical content, decided by one field. OSA emitted
  that field on the native Anthropic path only, so every Claude model reached
  through OpenRouter — which is how the benchmarks actually run — paid the full
  uncached rate on a ~30k-token prefix that never changed. That is the 0% cache
  hit rate; it was never the timestamp.

  Deliberately narrow. `cache_control` is an Anthropic wire field, and an
  OpenAI-compatible gateway is only obliged to forward it when the upstream is
  Anthropic. Gating on the model prefix as well as the provider means a
  `openai/*` or `google/*` model routed through the same gateway keeps the
  exact bytes it has today, so this cannot regress a non-Claude route.
  """
  @spec anthropic_prompt_cache?(atom() | {:compat, atom()}, String.t() | nil) :: boolean()
  def anthropic_prompt_cache?(target, model \\ nil)
  def anthropic_prompt_cache?(:anthropic, _model), do: true
  def anthropic_prompt_cache?(Providers.Anthropic, _model), do: true

  def anthropic_prompt_cache?(provider, model)
      when provider in [:openrouter, {:compat, :openrouter}] and is_binary(model),
      do: String.starts_with?(model, "anthropic/")

  def anthropic_prompt_cache?(_target, _model), do: false

  @doc """
  True for providers whose prompt cache is a plain **byte-prefix** match of the
  request — the local runtimes (Ollama, LM Studio, llama.cpp). Their llama.cpp
  KV cache reuses the longest identical prefix and re-prefills from the first
  changed byte; there is no `cache_control` field to place breakpoints with.

  `Agent.Context` uses this to keep the volatile block (clock, turn count,
  recall) OUT of the system message and in a trailing message instead, so the
  stable system-prompt-plus-history prefix stays byte-identical turn to turn and
  the cache reuses all of it — the plain-prefix analogue of what
  `Providers.PromptCache` does for the Anthropic route. Anthropic itself is
  excluded here: it has its own `cache_control` path and must not be double-handled.
  """
  @spec plain_prefix_cache?(atom() | {:compat, atom()}, String.t() | nil) :: boolean()
  def plain_prefix_cache?(provider, model \\ nil)
  def plain_prefix_cache?(p, _model) when p in [:ollama, :lmstudio, :llamacpp], do: true

  def plain_prefix_cache?({:compat, p}, _model) when p in [:ollama, :lmstudio, :llamacpp],
    do: true

  def plain_prefix_cache?(_target, _model), do: false

  @doc """
  The model this request will actually be served by — never the raw `opts` value.

  `is_binary(model)` in `anthropic_prompt_cache?/2` is correct as a guard and
  wrong as a question, because `opts[:model]` is `nil` on every non-CLI entry
  point: `Agent.Loop.LLMClient` only puts `:model` into `opts` when
  `state.model` is set, and `state.model` is nil under `serve`/HTTP and in the
  benchmark harness (`Agent.Context` says so at its own `model` resolution and
  resolves around it for exactly this reason).

  MEASURED on this tree, `{:compat, :openrouter}` with an
  `anthropic/claude-sonnet-4.5` default: with `:model` in opts, 1 `cache_control`
  breakpoint survives `flatten_message_content/4`; without it, 0. The request
  still goes to a Claude model — `OpenAICompat` fills the model in from the
  provider default further down — so the predicate was answering "what did the
  caller name?" when the question is "what is being served?". By the numbers in
  the doc above that is the difference between a 93.5% and a 0% hit rate, i.e.
  it silently re-opened the defect that doc was written about, for every
  headless session.

  Resolution is the same cascade `Agent.Context` uses: the named model, else the
  provider's configured model. Deliberately scoped to the cache decision — the
  sibling image gate on the line above reads `opts[:model]` too, but it already
  fails OPEN on nil, so widening it there is a behaviour change with no defect
  behind it.
  """
  @spec resolved_model(atom() | {:compat, atom()}, keyword()) :: String.t() | nil
  def resolved_model(target, opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        key = :"#{provider_key(target)}_model"

        case Application.get_env(:optimal_system_agent, key) do
          model when is_binary(model) and model != "" -> model
          _ -> nil
        end
    end
  end

  # `{:compat, _}` is served by `OpenAICompat`, whose `encode_content/1` emits
  # OpenAI `image_url` parts. Every other target is asked directly; a module
  # that does not export the predicate cannot carry images.
  defp transport_carries_images?({:compat, _provider}), do: true

  defp transport_carries_images?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :supports_image_content?, 0) and
      module.supports_image_content?()
  end

  defp transport_carries_images?(_), do: false

  defp provider_key({:compat, provider}), do: provider

  defp provider_key(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
      module.name()
    else
      :unknown
    end
  rescue
    _ -> :unknown
  end

  defp provider_key(_), do: :unknown

  # Which of the two refusals actually applies, so the placeholder can say the
  # true thing rather than one sentence covering both.
  defp omission_reason(target) do
    if transport_carries_images?(target), do: :model, else: :transport
  end

  defp structured_content?(%{content: c}) when is_list(c), do: true
  defp structured_content?(%{"content" => c}) when is_list(c), do: true
  defp structured_content?(_msg), do: false

  defp flatten_message_content(%{content: c} = msg, carry_images?, keep_cache?, reason)
       when is_list(c) do
    cond do
      carry_images? and Enum.any?(c, &image_block?/1) -> msg
      keep_cache? and Enum.any?(c, &cache_marked?/1) -> msg
      true -> %{msg | content: flatten_blocks(c, reason)}
    end
  end

  defp flatten_message_content(%{"content" => c} = msg, carry_images?, keep_cache?, reason)
       when is_list(c) do
    cond do
      carry_images? and Enum.any?(c, &image_block?/1) -> msg
      keep_cache? and Enum.any?(c, &cache_marked?/1) -> msg
      true -> Map.put(msg, "content", flatten_blocks(c, reason))
    end
  end

  defp flatten_message_content(msg, _carry_images?, _keep_cache?, _reason), do: msg

  defp cache_marked?(%{cache_control: cc}) when not is_nil(cc), do: true
  defp cache_marked?(%{"cache_control" => cc}) when not is_nil(cc), do: true
  defp cache_marked?(_), do: false

  defp image_block?(%{type: t}) when t in ["image", "image_url", :image, :image_url], do: true
  defp image_block?(%{"type" => t}) when t in ["image", "image_url"], do: true
  defp image_block?(%{"image" => _}), do: true
  defp image_block?(%{"inlineData" => _}), do: true
  defp image_block?(_), do: false

  # The separator is `"\n\n"` and the empty-block rejection is deliberate: it
  # reproduces `Context.build_system_message/4`'s own non-Anthropic branch
  # (`[static_base, world_state, volatile] |> Enum.reject(&(&1 == "")) |>
  # Enum.join("\n\n")`) exactly, so a flattened system prompt is BYTE-IDENTICAL
  # to the string these providers received before the cache fix split it into
  # blocks. Anything else here would silently rewrite every non-Anthropic prompt.
  #
  # `cache_control` is dropped rather than translated: it is an Anthropic-only
  # wire field. It survives untouched on the Anthropic path, which never reaches
  # this function.
  defp flatten_blocks(blocks, reason) do
    blocks
    |> Enum.map(&block_to_text(&1, reason))
    |> Enum.reject(&(&1 == nil or &1 == ""))
    |> Enum.join("\n\n")
  end

  # An image block that cannot be carried becomes a placeholder, so the model is
  # told the image is missing instead of hallucinating its contents. The text
  # names the ACTUAL reason: one sentence covering both cases was wrong for at
  # least one of them, and "this provider does not accept inline image content"
  # is now false for every target that reaches the carve-out.
  #
  # The other two ways an image can go missing say their own true thing
  # elsewhere: evicted for the size budget (`ImageBudget.placeholder/0`) and
  # refused at ingestion (`MessageHandler.build_messages/3`'s rejection
  # directive).
  @image_omitted_transport "[An image was attached, but OSA's integration for the provider serving this request cannot send images, so it was not sent. Do not describe or reason about its contents; tell the user to switch to a provider that accepts images.]"

  @image_omitted_model "[An image was attached, but the model serving this request does not accept image input, so it was not sent. Do not describe or reason about its contents; tell the user to switch to a vision-capable model.]"

  defp image_omitted(:transport), do: @image_omitted_transport
  defp image_omitted(:model), do: @image_omitted_model
  defp image_omitted(_), do: @image_omitted_transport

  defp block_to_text(block, _reason) when is_binary(block), do: block
  defp block_to_text(%{text: t}, _reason) when is_binary(t), do: t
  defp block_to_text(%{"text" => t}, _reason) when is_binary(t), do: t

  defp block_to_text(%{type: t}, reason) when t in ["image", "image_url", :image, :image_url],
    do: image_omitted(reason)

  defp block_to_text(%{"type" => t}, reason) when t in ["image", "image_url"],
    do: image_omitted(reason)

  # Anything else structured (a stray tool_use/tool_result block, say) carries no
  # text these providers can render; dropping it is what `Anthropic`'s own
  # `system_content_to_blocks/1` does with unreadable blocks.
  defp block_to_text(block, _reason) when is_map(block), do: nil

  defp block_to_text(other, _reason) do
    if String.Chars.impl_for(other), do: to_string(other), else: inspect(other)
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
        report_stream_downgrade(module, :primary)
        fallback_sync_stream(module, messages, callback, opts)
      end

    case primary_result do
      :ok ->
        :ok

      {:error, reason} ->
        # Snapshot the one-way door BEFORE anything else runs: every entry into
        # `Resilience.with_retry/2` clears the flag, and both the sync attempt
        # and the provider chain below go through it.
        if Resilience.output_observed?() do
          # OUTPUT ALREADY ON SCREEN. `Resilience.do_retry/7` refuses to retry
          # past this point for exactly one reason — a retry re-runs the
          # provider against the SAME live callback, so bytes the user already
          # watched render get emitted a second time. Every fallback below has
          # that identical property: `fallback_sync_stream/4` pushes the WHOLE
          # sync response through the same callback as one `:text_delta`, and
          # each hop of `stream_fallback_chain/5` re-streams the response from
          # scratch. So the retry suppression was a one-way door with a side
          # entrance: `with_retry` correctly declined to retry and handed the
          # error here, where the fallback promptly re-emitted the duplicate
          # `with_retry` had just prevented — a partial paragraph followed by
          # the full answer, or the same answer twice from two providers.
          #
          # Past this door the only honest options are "finish" or "fail".
          Logger.warning(
            "Provider #{provider} stream failed after output was already streamed to the " <>
              "user — not falling back (it would duplicate what is on screen): " <>
              Resilience.reason_to_string(reason)
          )

          {:error, reason}
        else
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
  end

  # Model/provider fallback for streaming — only reached after same-provider
  # retries (and a same-provider sync attempt) are exhausted.
  defp stream_fallback_chain(provider, messages, callback, opts, reason) do
    fallback_chain = Application.get_env(:optimal_system_agent, :fallback_chain, [])

    remaining_chain =
      if should_fallback?(reason) do
        fallback_chain
        |> Enum.drop_while(&(&1 == provider))
        |> then(fn
          chain when chain == fallback_chain -> chain
          [_ | rest] -> rest
          [] -> []
        end)
        |> filter_boot_excluded_providers()
      else
        # Same policy the sync path has enforced since finding #9, which this
        # path was simply missing: a non-transient failure — invalid request,
        # bad request shape, auth, model-not-found, context overflow — is not
        # provider-specific. Re-sending it only produces a SECOND, unrelated
        # error from the next provider, and because the chain reported its LAST
        # error, that impostor is what the user saw. A malformed tool_use in the
        # history surfaced as an Ollama JSON parse error on a session configured
        # for Anthropic, which is why switching models appeared to change nothing.
        Logger.warning(
          "Provider #{provider} stream failed with a non-transient error — not falling back: " <>
            Resilience.reason_to_string(reason)
        )

        []
      end

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

      Enum.reduce_while(remaining_chain, {:error, reason}, fn fb_provider, acc ->
        case Map.get(@providers, fb_provider) do
          nil ->
            Logger.warning("Unknown fallback provider: #{fb_provider}")
            {:cont, acc}

          fb_module ->
            case try_stream_provider(fb_module, messages, callback, cross_provider_opts(opts)) do
              :ok ->
                emit_serving_provider(fb_provider, opts)
                {:halt, :ok}

              {:error, r} ->
                Logger.warning(
                  "Fallback stream provider #{fb_provider} failed: #{Resilience.reason_to_string(r)}"
                )

                # Keep the PRIMARY reason as the accumulator. It is the only
                # actionable one: the fallback hops are collateral, and reporting
                # the last hop's error is what made an Anthropic history bug read
                # as an Ollama failure.
                #
                # And stop here if THIS hop already put bytes on screen: the next
                # hop re-streams the answer from scratch into the same live
                # callback, so the user would watch a partial answer followed by a
                # whole second one. Same one-way door as the primary attempt.
                if Resilience.output_observed?() do
                  Logger.warning(
                    "Fallback provider #{fb_provider} failed after streaming output to the " <>
                      "user — stopping the chain rather than duplicating what is on screen"
                  )

                  {:halt, acc}
                else
                  {:cont, acc}
                end
            end
        end
      end)
    end
  end

  # True when the module can stream natively (so it is worth wrapping in the
  # same-provider retry loop rather than dropping straight to sync).
  defp stream_capable?({:compat, _provider}), do: true

  # `Code.ensure_loaded?/1` is load-bearing, and its absence here was a real (if
  # narrow) bug: `function_exported?/3` answers `false` for a module that has not
  # been loaded YET, which under interactive/lazy loading is any provider module
  # on its first touch. The false negative sent a perfectly streaming provider
  # down `fallback_sync_stream/4` — one blocking call pushed through the callback
  # as a single delta, and the same-provider retry loop skipped — with nothing
  # said. Its sibling `transport_carries_images?/1` above already guards this
  # way; the two now agree.
  defp stream_capable?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :chat_stream, 3)

  # A single native streaming attempt — NO sync fallback. Returns
  # `:ok | {:error, reason}` so `Resilience.with_retry/2` can classify the
  # error and decide whether to retry the same provider.
  defp native_stream(target, messages, callback, opts) do
    do_native_stream(target, normalize_outbound_messages(messages, target, opts), callback, opts)
  end

  defp do_native_stream({:compat, provider}, messages, callback, opts) do
    @compat.chat_stream(provider, messages, callback, opts)
  rescue
    e -> {:error, "Compat provider #{provider} streaming raised: #{Exception.message(e)}"}
  end

  defp do_native_stream(module, messages, callback, opts) when is_atom(module) do
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

  defp try_stream_provider(target, messages, callback, opts) do
    do_try_stream_provider(
      target,
      normalize_outbound_messages(messages, target, opts),
      callback,
      opts
    )
  end

  defp do_try_stream_provider({:compat, provider}, messages, callback, opts) do
    # Compat providers now support chat_stream via OpenAICompatProvider
    try do
      @compat.chat_stream(provider, messages, callback, opts)
    rescue
      e ->
        Logger.warning(
          "Compat provider #{provider} streaming failed: #{Exception.message(e)}, falling back to sync"
        )

        fallback_sync_stream_unless_observed(
          {:compat, provider},
          messages,
          callback,
          opts,
          "compat provider #{provider} streaming raised: #{Exception.message(e)}"
        )
    end
  end

  defp do_try_stream_provider(module, messages, callback, opts) when is_atom(module) do
    # `stream_capable?/1`, not a bare `function_exported?/3`. The comment on
    # that function describes this exact defect — `function_exported?` answers
    # `false` for a module that has not been LOADED yet — and the guard was
    # added at the primary entrance (`stream_with_fallback/5`) and not at this
    # one, the provider-fallback hop. A fallback provider is by definition a
    # module this process has not touched yet this run, so the unguarded twin
    # sits on the path where the false negative is most likely, not least.
    if stream_capable?(module) do
      try do
        Logger.info("[Registry] Calling #{module}.chat_stream/3")

        case module.chat_stream(messages, callback, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Provider #{module} chat_stream failed: #{inspect(reason)} — falling back to sync"
            )

            fallback_sync_stream_unless_observed(module, messages, callback, opts, reason)
        end
      rescue
        e ->
          Logger.error("Provider #{module} chat_stream raised: #{Exception.message(e)}")

          fallback_sync_stream_unless_observed(
            module,
            messages,
            callback,
            opts,
            "provider #{inspect(module)} chat_stream raised: #{Exception.message(e)}"
          )
      end
    else
      # Provider cannot stream at all — nothing was emitted, so the whole-body
      # push is the only delivery and is safe.
      report_stream_downgrade(module, :fallback_hop)
      fallback_sync_stream(module, messages, callback, opts)
    end
  end

  @doc false
  # A working stream announces itself (`Logger.info "Calling …chat_stream/3"`);
  # a LOST stream said nothing at either entrance. That asymmetry is the one
  # `report_dropped_images/4` was written to remove for images, on the stated
  # principle that a capability silently removed must never be something
  # someone has to go looking for. Streaming had not been given the same
  # treatment, so a provider that quietly delivers the whole body as one
  # `:text_delta` is indistinguishable from one that streams badly.
  @spec report_stream_downgrade(module(), atom()) :: :ok
  def report_stream_downgrade(module, entrance) do
    :telemetry.execute(
      [:osa, :stream, :downgraded],
      %{count: 1},
      %{provider: module, entrance: entrance}
    )

    key = {module, entrance}

    if Process.get(:osa_stream_downgrade) != key do
      Process.put(:osa_stream_downgrade, key)

      Logger.warning(
        "[Registry] #{inspect(module)} does not implement chat_stream/3 (#{entrance}) — " <>
          "the response will arrive as a single block, not a live stream"
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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

  defp apply_provider(target, messages, opts) do
    do_apply_provider(target, normalize_outbound_messages(messages, target, opts), opts)
  end

  defp do_apply_provider({:compat, provider}, messages, opts) do
    try do
      @compat.chat(provider, messages, opts)
    rescue
      e ->
        Logger.error("Provider #{provider} raised: #{Exception.message(e)}")
        {:error, "Provider error: #{Exception.message(e)}"}
    end
  end

  defp do_apply_provider(module, messages, opts) when is_atom(module) do
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
    # OpenRouter stealth model (not yet in models.dev): Ox Alpha ships a
    # 1,048,576-token context window. Without this row the context meter would
    # fall back to a flat default and badly misreport occupancy on a 1M model.
    "stealth/ox-alpha" => 1_048_576,
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
    # Google, DeepSeek, xAI and Mistral are NOT listed here — they are merged in
    # below from Providers.GoogleModels / DeepSeekModels / XAIModels /
    # MistralModels, which are the single sources of truth for their catalogs.
    #
    # `deepseek-chat` / `deepseek-reasoner` (retired 2026-07-24) keep a row only
    # so an existing pinned config resolves to a sane budget rather than the
    # flat 128k default while the user migrates.
    "deepseek-chat" => 128_000,
    "deepseek-reasoner" => 128_000,
    # Groq (context varies by model). `mixtral-8x7b-32768` was shut down
    # 2025-03-20 and is removed. The Llama pair shuts down 2026-08-16; Groq
    # documents both at 131,072, not the 128,000 recorded here previously.
    "openai/gpt-oss-120b" => 131_072,
    "openai/gpt-oss-20b" => 131_072,
    "llama-3.3-70b-versatile" => 131_072,
    "llama-3.1-8b-instant" => 131_072,
    # Cohere. The undated `command-r-plus` / `command-r` aliases were shut down
    # 2025-09-15; the dated variants below are still served.
    "command-a-plus-05-2026" => 128_000,
    "command-a-03-2025" => 256_000,
    "command-r-plus-08-2024" => 128_000,
    "command-r-08-2024" => 128_000,
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
    # `deepseek-v4-pro` / `deepseek-v4-flash` deliberately have NO row here.
    # They used to, at 524_288 / 1_048_576 — the windows of Ollama's local
    # quantized builds. But the SAME bare ids are DeepSeek's own first-party
    # API models, which serve 1,048,576 for both, and this table is keyed by
    # model name with no provider, so one row cannot be right for both. The
    # DeepSeek catalog now owns them (merged below); the Ollama path is
    # unaffected because cloud tags are exact keys from `OllamaCloud` and are
    # probed live via /api/show anyway, which wins over any static row.
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
  # Hosted-provider catalogs are the single source of truth for their own
  # models and are merged LAST so they win over any stale hand-written row
  # above (the Anthropic/OpenAI rows in @static_context_windows are retained
  # only for older ids the catalogs no longer list).
  @fallback_context_windows @static_context_windows
                            |> Map.merge(
                              OptimalSystemAgent.Providers.OllamaCloud.context_windows()
                            )
                            |> Map.merge(
                              OptimalSystemAgent.Providers.AnthropicModels.context_windows()
                            )
                            |> Map.merge(
                              OptimalSystemAgent.Providers.OpenAIModels.context_windows()
                            )
                            |> Map.merge(
                              OptimalSystemAgent.Providers.GoogleModels.context_windows()
                            )
                            |> Map.merge(
                              OptimalSystemAgent.Providers.DeepSeekModels.context_windows()
                            )
                            |> Map.merge(OptimalSystemAgent.Providers.XAIModels.context_windows())
                            |> Map.merge(
                              OptimalSystemAgent.Providers.MistralModels.context_windows()
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
    # SSoT first — see ModelLimits.max_output/1 for why the catalog must not
    # win for Anthropic/OpenAI models (the bundled models.dev snapshot lags and
    # under-reports their windows).
    case ssot_context_window(model) || catalog_context_window(model) ||
           Map.get(@fallback_context_windows, model) do
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

  defp ssot_context_window(model) do
    case OptimalSystemAgent.Providers.AnthropicModels.resolve(model) do
      %{ctx: ctx} ->
        ctx

      nil ->
        case OptimalSystemAgent.Providers.OpenAIModels.resolve(model) do
          %{ctx: ctx} -> ctx
          nil -> nil
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
  def effective_context_window(model, :openai_codex),
    do: Providers.OpenAICodex.context_window(model) || context_window(model)

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
  def effective_context_window_info(model, :openai_codex) do
    case Providers.OpenAICodex.context_window(model) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> context_window_info(model)
    end
  end

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
      ceiling = OptimalSystemAgent.LocalModels.num_ctx_ceiling(model)

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

  # A model id can appear under MANY catalog sections — `claude-opus-5` ships
  # under anthropic, azure, azure-cognitive-services, github-copilot,
  # llmgateway, opencode and venice in the models.dev snapshot. `Catalog.find/1`
  # returns whichever one the underlying map happens to yield first, which is
  # hash order, not preference order: `azure` won, `provider_id_to_atom/1` maps
  # `"azure" -> :openai`, and so `/model claude-opus-5` switched the session to
  # the OPENAI provider carrying an Anthropic model id — a 404 on every
  # subsequent turn, for the single most likely model a user types.
  #
  # So: consider EVERY section carrying the model and prefer the one whose id
  # is the provider's own name (`"anthropic"` for `:anthropic`) over a reseller
  # or aggregator that merely relists it. Only if no section names a routable
  # provider directly do we fall back to the alias mapping.
  defp catalog_provider_for(model) do
    candidates = safe_catalog_providers_for(model)

    native =
      Enum.find_value(candidates, fn pid ->
        atom = exact_provider_atom(pid)
        if atom && Map.has_key?(@providers, atom), do: atom
      end)

    native ||
      Enum.find_value(candidates, fn pid ->
        case provider_id_to_atom(pid) do
          atom when is_atom(atom) -> if Map.has_key?(@providers, atom), do: atom
          _ -> nil
        end
      end)
  end

  # Catalog provider ids that carry this exact model id, in a STABLE order
  # (sorted), so resolution can never depend on map iteration order.
  defp safe_catalog_providers_for(model) do
    catalog = OptimalSystemAgent.Providers.Catalog

    catalog.providers()
    |> Enum.sort()
    |> Enum.filter(&catalog.model(&1, model))
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # A catalog id that IS the provider's own registered name — never an alias.
  defp exact_provider_atom(pid) do
    Enum.find(Map.keys(@providers), &(Atom.to_string(&1) == pid))
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

      # A Hugging Face GGUF pulled straight into the daemon
      # (`ollama pull hf.co/<user>/<repo>:<quant>`) keeps the `hf.co/` prefix as
      # its tag. Nothing but local Ollama serves those ids; without this branch
      # they fell to nil and were handed to whatever the node's default provider
      # was (Ollama Cloud on a `:cloud` default), which does not have the model.
      String.starts_with?(m, "hf.co/") or String.starts_with?(m, "huggingface.co/") ->
        :ollama

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

      # Groq serves the OpenAI open-weight models under a namespaced id
      # ("openai/gpt-oss-120b"). It must be matched explicitly: the id does not
      # start with "gpt", so without this branch it falls through to nil rather
      # than routing to :groq. It is now Groq's default model, so nil routing
      # would break the provider outright.
      String.starts_with?(m, "openai/gpt-oss") ->
        :groq

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
  # That sentence was aspirational until the connect bound below existed: the
  # probe measured 5017ms against an unreachable host while claiming 3s, which
  # is longer than the `GenServer.call` it runs inside is willing to wait. It is
  # true now, and `ContextProbeFitsInsideACallTest` keeps it true — it asserts
  # the probe finishes with real headroom under the 5000ms call default, not
  # merely under it.
  #
  # The failure is cached PERMANENTLY only when the daemon actually answered and
  # the answer contained no context length (a definitive "this model does not
  # report one"). Transport failures get a short TTL instead — see
  # `@negative_ttl_ms`. Conflating the two is what let a single failed probe at
  # startup pin a model's window to "unknown" forever.
  @probe_timeout_ms 3_000

  defp fetch_ollama_context(model) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    # `connect_options` is load-bearing, not belt-and-braces. `receive_timeout`
    # bounds only the wait for a RESPONSE; establishing the connection and
    # checking one out of the pool fall back to Finch's own 5s default. So the
    # "3s" budget above measured 5017ms against a black-holed host — and this
    # probe runs inside `Loop.handle_call({:swap_provider, ...})`, whose
    # callers use the 5000ms `GenServer.call` default. The caller gave up 17ms
    # before the server finished, and the server then completed the swap: a
    # model change that lands and reports failure.
    #
    # A refused connection returns instantly and never showed this. A remote
    # Ollama, a loaded machine or a half-open socket does not get refused — it
    # hangs, which is exactly the configuration this probe exists for.
    opts =
      [
        json: %{name: model},
        receive_timeout: @probe_timeout_ms,
        connect_options: [timeout: @probe_timeout_ms],
        retry: false
      ] ++
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

  # Bedrock has no `BEDROCK_API_KEY`, so the generic clause below would always
  # answer "not configured" for it. It is configured when EITHER a Bedrock
  # bearer key is present OR the account connection was made — the latter
  # being a pure read of the connection marker, never a fresh AWS call, so
  # asking "is this configured?" cannot cost a request.
  def provider_configured?(:bedrock) do
    case OptimalSystemAgent.Onboarding.live_env("AWS_BEARER_TOKEN_BEDROCK") do
      v when is_binary(v) and v != "" ->
        true

      _ ->
        OptimalSystemAgent.Auth.SubscriptionStore.connected?("bedrock")
    end
  rescue
    _ -> false
  end

  # Qwen is dual-mode for the same reason xAI is: a `QWEN_API_KEY` OR a
  # connected Qwen account. Pure read of the marker — never a token call.
  def provider_configured?(:qwen) do
    case Application.get_env(:optimal_system_agent, :qwen_api_key) do
      key when is_binary(key) and key != "" ->
        true

      _ ->
        live_cloud_key_present?(:qwen) or
          OptimalSystemAgent.Auth.SubscriptionStore.connected?("qwen")
    end
  rescue
    _ -> false
  end

  # xAI is dual-mode: an `XAI_API_KEY` OR a connected xAI account. The generic
  # clause below sees only the key, so a user who signed in with their
  # SuperGrok plan and pasted nothing would be told the provider is not
  # configured — which is exactly the state the sign-in exists to leave them
  # in. The account half is a pure read of the connection marker (never a
  # fresh token call), so asking "is this configured?" cannot spend a refresh
  # token or bill a request. Same shape as `:bedrock` above.
  def provider_configured?(:xai) do
    case Application.get_env(:optimal_system_agent, :xai_api_key) do
      key when is_binary(key) and key != "" ->
        true

      _ ->
        live_cloud_key_present?(:xai) or
          OptimalSystemAgent.Auth.SubscriptionStore.connected?("xai")
    end
  rescue
    _ -> false
  end

  # Boot-time `Application.get_env` is a one-shot snapshot taken when
  # `config/runtime.exs` ran. A key added to `~/.osa/.env` afterward by a
  # different OS process (the CLI setup wizard, `osa setup`, a hand edit)
  # never reaches it, so a lone cloud key can report "not configured" even
  # though it plainly is (P2/P3). Fall back to a live re-read before saying no.
  def provider_configured?(provider) do
    key = :"#{provider}_api_key"

    case Application.get_env(:optimal_system_agent, key) do
      nil -> live_cloud_key_present?(provider) or connected_account?(provider)
      "" -> live_cloud_key_present?(provider) or connected_account?(provider)
      _ -> true
    end
  end

  # Account sign-in is a provider-wide credential source, just like an API
  # key. Keep this in the generic path so every current and future provider
  # registered with Auth.Subscription is reflected consistently by /model,
  # doctor, routing, and the TUI instead of requiring another provider-specific
  # clause each time account auth is added.
  defp connected_account?(provider) do
    OptimalSystemAgent.Auth.Subscription.supported?(provider) and
      OptimalSystemAgent.Auth.SubscriptionStore.connected?(provider)
  rescue
    _ -> false
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

  @doc """
  The model a turn will actually run on when nothing named one explicitly.

  A session started without an explicit `:model` used to carry `model: nil`
  all the way through, and nil is not an absence — it is a value that silently
  breaks everything keyed on the model:

    * pricing logs `No price for model nil`, so `session_cost_usd` stays 0 and
      `max_budget_usd` can never trip;
    * `Loop.ContextWindow.resolve/1` returns `:unknown`, so the pressure meter
      reports `max=0 util=0.0%` and `above_compact` can never become true —
      **compaction never fires for the whole session**.

  Measured across a 40-instance benchmark run: 37 of 40 sessions reported a
  zero context window for exactly this reason.

  Resolution mirrors what the request path already does — the provider's own
  `default_model/0` — so the state agrees with the wire instead of guessing.
  """
  @spec resolved_default_model(atom() | nil) :: String.t() | nil
  def resolved_default_model(provider \\ nil) do
    provider = provider || resolved_default_provider()

    # Honor a persisted per-provider choice first. A model switch writes the
    # scoped :"#{provider}_model" key (config.json + app-env), and that should
    # win over the catalog default so a new session picks up what the user last
    # selected. Ollama already reads :ollama_model; this extends the same
    # courtesy to every provider. Falls back to the provider's catalog default
    # (e.g. glm-5.2:cloud) when nothing has been persisted.
    case Application.get_env(:optimal_system_agent, :"#{provider}_model") do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        # provider_info/1 replies {:ok, map}. Matching a bare map here silently
        # yielded nil for every provider — the same tuple-vs-map slip that made
        # `osa.run --format json` report a cost of 0.
        case provider_info(provider) do
          {:ok, %{default_model: model}} when is_binary(model) and model != "" -> model
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

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
