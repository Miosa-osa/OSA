defmodule OptimalSystemAgent.Providers.OpenAICompatProvider do
  @moduledoc """
  Consolidated OpenAI-compatible provider — handles 13 providers through one module.

  Instead of 13 near-identical wrapper modules, this single module stores provider
  configs and dispatches to OpenAICompat.chat/5 with the correct URL, API key, and model.

  Covers: openai, groq, deepseek, together, fireworks, perplexity, mistral,
  openrouter, qwen, moonshot, zhipu, volcengine, baichuan.
  """

  alias OptimalSystemAgent.Providers.OpenAICompat

  # Every provider routed through here goes out via `OpenAICompat`, which puts
  # the tool schemas in the request body's `tools` field.
  # See Providers.Behaviour.native_tool_schemas?/0.
  def native_tool_schemas?, do: true

  @provider_configs %{
    openai: %{
      default_url: "https://api.openai.com/v1",
      default_model: OptimalSystemAgent.Providers.OpenAIModels.default_model(),
      available_models: OptimalSystemAgent.Providers.OpenAIModels.ids()
    },
    # `mixtral-8x7b-32768` was shut down by Groq on 2025-03-20 and is removed.
    # The two Llama ids are still live but Groq has scheduled them for shutdown
    # on 2026-08-16, so the default moves to `openai/gpt-oss-120b` — Groq's own
    # named migration target and its top production model with no pending
    # shutdown (131,072 context / 65,536 max completion tokens).
    #
    # Sources: https://console.groq.com/docs/models and
    # https://console.groq.com/docs/deprecations (checked 2026-08-01).
    groq: %{
      default_url: "https://api.groq.com/openai/v1",
      default_model: "openai/gpt-oss-120b",
      # The two Llama ids are REMOVED, not just demoted from default. They still
      # work today, which is exactly why leaving them in the picker was unsafe:
      # a user would select one now and break on 2026-08-16, fifteen days out.
      # The 90-day guard in model_retirement_test.exs enforces this.
      available_models: [
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b"
      ]
    },
    # `deepseek-chat` / `deepseek-reasoner` were FULLY RETIRED 2026-07-24 —
    # both the default and every tier entry were dead. Thinking also moved from
    # a separate model id onto an `extra_body.thinking` request parameter; see
    # Providers.DeepSeekModels for the routing consequences.
    deepseek: %{
      default_url: "https://api.deepseek.com/v1",
      default_model: OptimalSystemAgent.Providers.DeepSeekModels.default_model(),
      available_models: OptimalSystemAgent.Providers.DeepSeekModels.ids()
    },
    together: %{
      default_url: "https://api.together.xyz/v1",
      default_model: "meta-llama/Llama-3.3-70B-Instruct-Turbo"
    },
    # `llama-v3p3-70b-instruct` still RESOLVES on Fireworks, which is why this
    # looked healthy — but its model card says "Serverless: Not supported", so
    # it is on-demand-dedicated-GPU only and every serverless call against it
    # fails. A resolving-but-unservable id is the worst kind of dead default.
    # `kimi-k2p7-code` is Fireworks' own named best serverless coding model
    # (262,144 ctx, $0.95/$4.00); `gpt-oss-120b` is the cheap portable tier.
    #
    # Source: https://fireworks.ai/models?infrastructure=serverless and
    # https://docs.fireworks.ai/serverless/pricing (checked 2026-08-01).
    fireworks: %{
      default_url: "https://api.fireworks.ai/inference/v1",
      default_model: "accounts/fireworks/models/kimi-k2p7-code",
      available_models: [
        "accounts/fireworks/models/kimi-k2p7-code",
        "accounts/fireworks/models/deepseek-v4-pro",
        "accounts/fireworks/models/deepseek-v4-flash",
        "accounts/fireworks/models/glm-5p2",
        "accounts/fireworks/models/gpt-oss-120b",
        "accounts/fireworks/models/gpt-oss-20b"
      ]
    },
    perplexity: %{
      default_url: "https://api.perplexity.ai",
      default_model: "sonar-pro"
    },
    mistral: %{
      default_url: "https://api.mistral.ai/v1",
      default_model: OptimalSystemAgent.Providers.MistralModels.default_model(),
      available_models: OptimalSystemAgent.Providers.MistralModels.ids()
    },
    # OpenRouter namespaces Anthropic ids with a DOT where Anthropic's own API
    # uses a DASH (`anthropic/claude-haiku-4.5`, not `-4-5`), so anything built
    # by concatenating "anthropic/" onto an Anthropic API id is unsafe for a
    # dotted version. Verified against the live GET /api/v1/models catalog
    # (2026-08-01); the ids below are all present in it.
    openrouter: %{
      default_url: "https://openrouter.ai/api/v1",
      default_model: "anthropic/claude-opus-5",
      available_models: [
        "anthropic/claude-opus-5",
        "anthropic/claude-sonnet-5",
        "anthropic/claude-haiku-4.5",
        "openai/gpt-5.6-sol",
        "google/gemini-3.6-flash",
        "deepseek/deepseek-v4-pro"
      ],
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
    },

    # ── Newly routed OpenAI-compatible providers ──────────────────────────
    # These were offered by onboarding + declared in runtime.exs provider_map
    # but had no registry routing, so selecting them crashed with
    # "Unknown provider: …". All are OpenAI-compatible, so one config each
    # (base_url + default_model) is enough to route them through this module.

    # MIOSA / Optimal — custom + trained models, run-your-own-harness.
    miosa: %{
      default_url: "https://optimal.miosa.ai/v1",
      default_model: "nemotron-3-miosa"
    },
    # xAI Grok. The bare `grok-4` default did not resolve at all — it is not in
    # xAI's model list. Note that xAI's RETIRED slugs do still resolve and
    # silently redirect (grok-3 → grok-4.3 at `none` effort), so a stale pin
    # keeps "working" while running a different model with reasoning off.
    xai: %{
      default_url: "https://api.x.ai/v1",
      default_model: OptimalSystemAgent.Providers.XAIModels.default_model(),
      available_models: OptimalSystemAgent.Providers.XAIModels.ids()
    },
    # Cerebras — ultra-fast inference. BOTH ids OSA carried were deprecated:
    # `llama-3.3-70b` on 2026-02-16 and `llama3.1-8b` on 2026-05-27, both with
    # `gpt-oss-120b` as Cerebras' own named replacement. Cerebras has no Llama
    # models left at all, and `gpt-oss-120b` is its ONLY Production-tier model
    # (`gemma-4-31b` and `zai-glm-4.7` are marked evaluation-only, and
    # `zai-glm-4.7` is itself already scheduled for deprecation 2026-08-17 —
    # deliberately not offered).
    #
    # NOTE: Cerebras' context window is ACCOUNT-TIER dependent — 131,072 on a
    # paid key but 65,536 on a free one, with max output 40,960 vs 32,768. The
    # static table records the paid figure; a free-tier key will be over-budgeted
    # until a runtime probe exists (see `Registry.effective_context_window_info/2`).
    #
    # Sources: https://inference-docs.cerebras.ai/models/overview and
    # https://inference-docs.cerebras.ai/support/deprecation (checked 2026-08-01).
    cerebras: %{
      default_url: "https://api.cerebras.ai/v1",
      default_model: "gpt-oss-120b",
      available_models: ["gpt-oss-120b"]
    },
    # SambaNova
    sambanova: %{
      default_url: "https://api.sambanova.ai/v1",
      default_model: "Meta-Llama-3.3-70B-Instruct"
    },
    # Hyperbolic
    hyperbolic: %{
      default_url: "https://api.hyperbolic.xyz/v1",
      default_model: "meta-llama/Llama-3.3-70B-Instruct"
    },
    # LM Studio — local, OpenAI-compatible server (no key needed)
    lmstudio: %{
      default_url: "http://localhost:1234/v1",
      default_model: "local-model",
      keyless: true
    },
    # llama.cpp server — local, OpenAI-compatible (no key needed)
    llamacpp: %{
      default_url: "http://localhost:8080/v1",
      default_model: "local-model",
      keyless: true
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

  @doc """
  The provider's base URL — the SAME value `chat/3` dials, honouring a
  `:<provider>_url` override.

  Read-only accessor. Exists so onboarding's health check can probe each
  provider at ITS OWN endpoint instead of keeping a second copy of this table:
  a duplicated URL list is how a Google/Groq key ended up being POSTed to
  `api.openai.com`. Raises for an unknown provider, same as every other
  accessor here.
  """
  @spec base_url(atom()) :: String.t()
  def base_url(provider) do
    Application.get_env(
      :optimal_system_agent,
      :"#{provider}_url",
      get_config!(provider).default_url
    )
  end

  @doc "True when this provider is a local server that needs no API key."
  @spec keyless?(atom()) :: boolean()
  def keyless?(provider), do: Map.get(get_config!(provider), :keyless, false)

  @doc false
  # Test/introspection seam for the private `resolve_api_key/2` — lets the
  # live-fallback resolution (P2/P3: Application snapshot → System.get_env →
  # ~/.osa/.env) be asserted directly without driving a real HTTP call.
  @spec resolved_api_key(atom()) :: String.t() | nil
  def resolved_api_key(provider), do: resolve_api_key(provider, get_config!(provider))

  @doc "Send a chat completion request through the named provider."
  def chat(provider, messages, opts \\ []) do
    config = get_config!(provider)

    with {:ok, api_key, url} <- resolve_credential(provider, config) do
      model =
        Keyword.get(opts, :model) ||
          Application.get_env(:optimal_system_agent, :"#{provider}_model", config.default_model)

      opts =
        opts
        |> Keyword.delete(:model)
        |> maybe_add_headers(config)
        |> maybe_extend_timeout(model)

      result =
        retry_once_on_rejected_account_token(provider, api_key, fn key ->
          OpenAICompat.chat(url, key, model, messages, opts)
        end)

      case result do
        {:error, "API key not configured"} ->
          {:error, "#{provider |> to_string() |> String.upcase()}_API_KEY not configured"}

        other ->
          other
      end
    end
  end

  @doc "Send a streaming chat completion request through the named provider."
  def chat_stream(provider, messages, callback, opts \\ []) do
    config = get_config!(provider)

    with {:ok, api_key, url} <- resolve_credential(provider, config) do
      model =
        Keyword.get(opts, :model) ||
          Application.get_env(:optimal_system_agent, :"#{provider}_model", config.default_model)

      opts =
        opts
        |> Keyword.delete(:model)
        |> maybe_add_headers(config)
        |> maybe_extend_timeout(model)

      result =
        retry_once_on_rejected_account_token(provider, api_key, fn key ->
          OpenAICompat.chat_stream(url, key, model, messages, callback, opts)
        end)

      case result do
        {:error, "API key not configured"} ->
          {:error, "#{provider |> to_string() |> String.upcase()}_API_KEY not configured"}

        other ->
          other
      end
    end
  end

  # ── Dual-mode credential resolution ─────────────────────────────────────
  #
  # A provider listed here offers a SECOND way in besides a pasted key: the
  # user's own account, connected through `Auth.Subscription`. Both modes
  # reach the same host with the same wire format and the same models — only
  # the credential differs — so they are one entry here rather than two.
  #
  # The value is the auth module, which owns the token and the base URL that
  # was pinned at sign-in. Nothing about the endpoint is duplicated into this
  # table.
  @account_modes %{
    qwen: OptimalSystemAgent.Auth.Providers.Qwen,
    xai: OptimalSystemAgent.Auth.Providers.XAI
  }

  # (Defined below `@account_modes`, which it reads — a module attribute is
  # only visible to code compiled after it.)
  #
  # Recover from a token the SERVER rejected but the CLIENT still believes in.
  #
  # `resolve_credential/2` refreshes on a DEADLINE — `needs_refresh?/1` and
  # `expired?/1` are arithmetic over `expires_at`. A deadline is not the only
  # way a token dies. A clock skewed past the refresh window, or a
  # provider-side revocation, leaves both predicates answering `false`
  # forever, so the same dead token was resolved, sent, 401'd and resolved
  # again on every single turn for the life of the OS process, with no path
  # back except the user noticing and re-running sign-in.
  #
  # One retry, and only for a token that came from an ACCOUNT: a pasted API
  # key has nothing to refresh (its 401 is a real "this key is wrong" and
  # must surface unchanged), and `force_refresh/1` is keyed on the rejected
  # token, so a peer process that already rotated the credential has its
  # fresh token adopted with no network call rather than double-spending the
  # single-use refresh token.
  # Public with `@doc false` for the same reason `resolved_credential/1` and
  # `resolved_api_key/1` are: the behaviour worth pinning is the DECISION
  # (retry or not, once or repeatedly, account or key), and `OpenAICompat`
  # offers no plug seam to drive that decision through a real HTTP call.
  @doc false
  @spec retry_once_on_rejected_account_token(atom(), String.t() | nil, (String.t() | nil ->
                                                                          term())) ::
          term()
  def retry_once_on_rejected_account_token(provider, api_key, fun) do
    case fun.(api_key) do
      {:error, msg} = err when is_binary(msg) ->
        with true <- rejected_credential?(msg),
             module when not is_nil(module) <- Map.get(@account_modes, provider),
             true <- is_binary(api_key) and api_key != "",
             {:ok, renewed} <- module.force_refresh(api_key),
             true <- renewed != api_key do
          fun.(renewed)
        else
          _ -> err
        end

      other ->
        other
    end
  end

  # `OpenAICompat` reports transport failures as `"HTTP <status>: <body>"`.
  # 401 is a rejected credential; 403 is an authorised credential without
  # entitlement, and refreshing that changes nothing, so it is not retried.
  defp rejected_credential?(msg), do: String.starts_with?(msg, "HTTP 401")

  @doc """
  The providers that can actually SPEND an account (subscription) credential.

  Published so an auth provider can ask "is there a transport for me?" instead
  of hardcoding the answer. `Auth.Providers.Copilot` uses it to refuse a
  sign-in that would store a bearer token nothing in this build can send —
  and, because the question is asked at runtime against this table, adding a
  provider here is all it takes to turn that sign-in back on.
  """
  @spec account_mode_providers() :: [atom()]
  def account_mode_providers, do: Map.keys(@account_modes)

  @doc "The auth module that owns a provider's account credential, or `nil`."
  @spec account_mode_module(atom()) :: module() | nil
  def account_mode_module(provider), do: Map.get(@account_modes, provider)

  @doc false
  # Test/introspection seam for `resolve_credential/2`.
  @spec resolved_credential(atom()) ::
          {:ok, String.t() | nil, String.t()} | {:error, String.t()}
  def resolved_credential(provider), do: resolve_credential(provider, get_config!(provider))

  # Decide WHICH credential this request carries, and therefore which URL it
  # goes to.
  #
  # A configured API key ALWAYS wins, and that ordering is what makes the key
  # path provably unchanged: whenever a key resolves, this function returns
  # exactly the `{key, url}` pair the previous code computed — same live-env
  # fallback, same `:<provider>_url` override — and no account code runs at
  # all. The account branch is reachable only in the case that previously
  # produced a nil key and a guaranteed "not configured" error. It is the same
  # precedence `bedrock` and `ollama_cloud` already use.
  #
  # Note the asymmetry on the URL, which is deliberate and is a security
  # boundary rather than an inconsistency: the key branch honours
  # `:<provider>_url`, the account branch does not. See
  # `Auth.Providers.XAI.pinned_base_url/0` for why an env override must never
  # be able to retarget a subscription bearer token.
  defp resolve_credential(provider, config) do
    case resolve_api_key(provider, config) do
      key when is_binary(key) and key != "" ->
        {:ok, key,
         Application.get_env(:optimal_system_agent, :"#{provider}_url", config.default_url)}

      _ ->
        account_credential(provider, config)
    end
  end

  defp account_credential(provider, config) do
    case Map.get(@account_modes, provider) do
      nil ->
        {:ok, nil,
         Application.get_env(:optimal_system_agent, :"#{provider}_url", config.default_url)}

      module ->
        # `connected?/0` is a pure read; `access_token/0` may refresh. Asking
        # the cheap question first means a provider with no account connected
        # falls through to the unchanged "no key" error instead of paying a
        # store read and an error round-trip for a credential that was never
        # going to exist.
        if module.connected?() do
          case module.access_token() do
            {:ok, token} ->
              {:ok, token, module.pinned_base_url()}

            {:error, reason} ->
              # The reason atom only ever describes a FAILURE MODE. The token
              # itself is never in it, is never logged, and is never rendered.
              {:error,
               OptimalSystemAgent.Auth.Subscription.message(reason, module.display_name())}
          end
        else
          {:ok, nil,
           Application.get_env(:optimal_system_agent, :"#{provider}_url", config.default_url)}
        end
    end
  end

  # Resolve the API key for a provider. Local, keyless servers (LM Studio,
  # llama.cpp) accept any bearer token, so when none is configured we substitute
  # a harmless placeholder rather than short-circuiting with
  # "API key not configured" — this keeps the local OpenAI-compatible path usable.
  #
  # `Application.get_env` is a one-shot snapshot taken when `config/runtime.exs`
  # ran at boot. A key added to `~/.osa/.env` afterward by a different OS
  # process (the CLI setup wizard, `osa setup`, a hand edit) never reaches it,
  # so a lone cloud key can silently sit unused while the compat provider keeps
  # reporting "API key not configured" (P2/P3). Fall back to a live re-read
  # (`Onboarding.live_env/1`: `System.get_env` then a fresh `.env` parse)
  # before giving up.
  defp resolve_api_key(provider, config) do
    case Application.get_env(:optimal_system_agent, :"#{provider}_api_key") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        case live_env_api_key(provider) do
          key when is_binary(key) and key != "" ->
            key

          _ ->
            if Map.get(config, :keyless, false), do: "not-needed", else: nil
        end
    end
  end

  defp live_env_api_key(provider) do
    env_var = provider |> Atom.to_string() |> String.upcase() |> Kernel.<>("_API_KEY")
    OptimalSystemAgent.Onboarding.live_env(env_var)
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
