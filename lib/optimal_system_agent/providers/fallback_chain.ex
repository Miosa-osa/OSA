defmodule OptimalSystemAgent.Providers.FallbackChain do
  @moduledoc """
  Fallback model chain — automatic provider switching on failure.

  When the primary provider fails (rate limit, downtime, error), tries
  the next provider in the chain. Configurable via:

      config :optimal_system_agent, :fallback_chain, [:anthropic, :openai, :groq, :ollama]

  Falls back silently — the agent continues working without interruption —
  with one deliberate exception. See `cost_gated_chain/2`: crossing from a
  free/local primary onto a metered provider is a decision with a bill
  attached and the user's prompt on the wire, so it is never taken silently and
  never taken on a chain the user did not choose.
  """
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Providers.{ErrorCatalog, Resilience, RetryClassifier}
  alias OptimalSystemAgent.Events.Bus

  @default_chain [:anthropic, :openai, :groq, :ollama]

  # Providers that bill nothing and keep the prompt on the user's own machine.
  # `:ollama_cloud` is deliberately NOT here: it proxies to ollama.com, so the
  # prompt leaves the box even if the plan is free.
  @free_providers [:ollama, :lmstudio]

  # Opt-in for the case the gate exists for: an unconfigured chain plus a
  # free/local primary. Set
  #     config :optimal_system_agent, :fallback_allow_paid, true
  # (or `fallback_allow_paid = true` in config.toml's equivalent) to let the
  # built-in chain spend money on the user's behalf.
  @allow_paid_key :fallback_allow_paid

  # Categories that always warrant a cross-provider fallback attempt: server
  # overload/5xx and rate-limit are provider-specific (another provider is not
  # currently overloaded/limited just because this one is), unlike
  # context-overflow which is prompt-size-driven and would fail identically
  # against the next provider too (excluded below, ahead of this list).
  @always_retryable_categories [:server_error, :server_overload, :rate_limit]

  # Auth/config failures — never worth a cross-provider fallback. Mirrors
  # RetryClassifier's @auth_categories plus :missing_api_key, so the sync path
  # (Registry.chat/2 delegates to retryable_error?/1) and the fallback path
  # agree that a rejected key must surface, not be papered over.
  @auth_config_categories [
    :auth,
    :invalid_api_key,
    :missing_api_key,
    :token_revoked,
    :oauth_org_not_allowed,
    :org_disabled
  ]

  @doc "Get the configured fallback chain."
  def chain do
    Application.get_env(:optimal_system_agent, :fallback_chain, @default_chain)
  end

  @doc "True for providers that cost nothing and keep the prompt on this machine."
  @spec free?(atom()) :: boolean()
  def free?(provider), do: provider in @free_providers

  @doc """
  The fallback chain a given primary is actually allowed to spend on.

  `@default_chain` hardcodes three metered providers ahead of the one free
  one, and `chain/0` returns it whenever the user has not configured a chain of
  their own. Combined with "falls back silently", that meant a user whose
  primary is `:ollama` — who chose a local model precisely so nothing is
  billed and nothing leaves the machine — was moved onto Anthropic on the first
  5xx, because an `ANTHROPIC_API_KEY` happened to be exported. Two things
  crossed a line the user never drew: their money, and their prompt.

  So: when the primary is free AND the chain is the built-in default (i.e. the
  user never chose it), paid hops are dropped. An explicitly configured chain
  is honoured as written — the user picked those providers — but the first paid
  hop from a free primary still announces itself.

  Returns the permitted chain. Emits at most one warning per VM per case.
  """
  @spec cost_gated_chain([atom()], atom()) :: [atom()]
  def cost_gated_chain(candidates, primary) do
    paid = Enum.reject(candidates, &free?/1)

    cond do
      not free?(primary) or paid == [] ->
        candidates

      Application.get_env(:optimal_system_agent, @allow_paid_key, false) ->
        warn_once(
          {:paid_allowed, primary},
          "[fallback] #{primary} failed; falling back to metered provider(s) " <>
            "#{inspect(paid)} because :#{@allow_paid_key} is enabled. Your prompt is " <>
            "being sent to a provider you did not select, and the call is billed."
        )

        candidates

      user_configured_chain?() ->
        warn_once(
          {:paid_configured, primary},
          "[fallback] #{primary} failed; falling back to metered provider(s) " <>
            "#{inspect(paid)} from your configured :fallback_chain. These calls are " <>
            "billed and your prompt leaves this machine."
        )

        candidates

      true ->
        free = Enum.filter(candidates, &free?/1)

        warn_once(
          {:paid_blocked, primary},
          "[fallback] #{primary} failed. NOT falling back to #{inspect(paid)} — those " <>
            "are metered providers from OSA's built-in default chain, not a chain you " <>
            "chose, and #{primary} is a free/local provider. Set " <>
            "config :optimal_system_agent, :#{@allow_paid_key}, true to allow it, or " <>
            "configure :fallback_chain explicitly."
        )

        free
    end
  end

  defp user_configured_chain?,
    do: Application.get_env(:optimal_system_agent, :fallback_chain) != nil

  # Logger alone is not "a warning the user actually sees" — OSA's TUI renders
  # the bus, not the log. Emit on both, once per distinct case per VM, so a
  # retry loop cannot turn this into a wall of text.
  defp warn_once(key, message) do
    pt_key = {__MODULE__, :warned, key}

    if :persistent_term.get(pt_key, false) == false do
      :persistent_term.put(pt_key, true)
      Logger.warning(message)

      try do
        Bus.emit(:system_event, %{event: :provider_cost_warning, message: message})
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Try a chat call across the fallback chain.

  Starts with the given provider, falls back to the next on failure.
  Returns `{:ok, result, provider_used}` or `{:error, reason}` if all fail.
  """
  def chat_with_fallback(messages, opts \\ []) do
    primary =
      Keyword.get(opts, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    # Build ordered chain: primary first, then configured fallbacks (excluding
    # primary), minus any metered hop the primary is not allowed to spend on.
    fallback_providers =
      chain()
      |> Enum.reject(fn p -> p == primary end)
      |> cost_gated_chain(primary)

    ordered = [primary | fallback_providers]

    try_providers(ordered, messages, opts, [])
  end

  @doc """
  Try a streaming chat call across the fallback chain.

  Same as chat_with_fallback but for streaming calls.
  """
  def chat_stream_with_fallback(messages, callback, opts \\ []) do
    primary =
      Keyword.get(opts, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    fallback_providers =
      chain()
      |> Enum.reject(fn p -> p == primary end)
      |> cost_gated_chain(primary)

    ordered = [primary | fallback_providers]

    try_stream_providers(ordered, messages, callback, opts, [])
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Both chains are built as `[primary | fallbacks]`, and `opts[:model]` was
  # resolved for the PRIMARY. The head must keep it — that is the model the user
  # actually asked for. Every later hop is a different provider, and forwarding
  # the primary's tag there asks e.g. Ollama for `claude-sonnet-5`, a tag its
  # daemon has never heard of. The hop then fails for a reason that has nothing
  # to do with the original fault, and because the chain reports the LAST error,
  # that impostor is the one the user sees.
  #
  # `errors == []` is exactly "no provider has been tried yet", i.e. the head.
  # Public as a test seam, like `Ollama.format_messages/1`: asserting this
  # mapping directly is far cheaper than standing up real provider HTTP.
  @doc false
  @spec hop_opts(keyword(), list()) :: keyword()
  def hop_opts(opts, []), do: opts
  def hop_opts(opts, _errors), do: Providers.cross_provider_opts(opts)

  defp try_providers([], _messages, _opts, errors) do
    error_summary = Enum.map(errors, fn {p, e} -> "#{p}: #{inspect(e)}" end) |> Enum.join("; ")
    {:error, "All providers failed: #{error_summary}"}
  end

  defp try_providers([provider | rest], messages, opts, errors) do
    opts_with_provider = Keyword.put(hop_opts(opts, errors), :provider, provider)

    case Providers.chat(messages, opts_with_provider) do
      {:ok, result} ->
        if errors != [] do
          Logger.info("[fallback] Succeeded with #{provider} after #{length(errors)} failure(s)")
        end

        {:ok, result, provider}

      {:error, reason} ->
        if retryable_error?(reason) do
          Logger.warning("[fallback] #{provider} failed: #{inspect(reason)}, trying next")
          try_providers(rest, messages, opts, errors ++ [{provider, reason}])
        else
          # Non-retryable error — don't try fallbacks
          {:error, reason}
        end
    end
  rescue
    e ->
      Logger.warning("[fallback] #{provider} crashed: #{Exception.message(e)}, trying next")
      try_providers(rest, messages, opts, errors ++ [{provider, Exception.message(e)}])
  end

  defp try_stream_providers([], _messages, _callback, _opts, errors) do
    error_summary = Enum.map(errors, fn {p, e} -> "#{p}: #{inspect(e)}" end) |> Enum.join("; ")
    {:error, "All providers failed: #{error_summary}"}
  end

  defp try_stream_providers([provider | rest], messages, callback, opts, errors) do
    opts_with_provider = Keyword.put(hop_opts(opts, errors), :provider, provider)

    case Providers.chat_stream(messages, callback, opts_with_provider) do
      {:ok, result} ->
        if errors != [] do
          Logger.info(
            "[fallback] Stream succeeded with #{provider} after #{length(errors)} failure(s)"
          )
        end

        {:ok, result, provider}

      {:error, reason} ->
        if retryable_error?(reason) do
          Logger.warning("[fallback] #{provider} stream failed: #{inspect(reason)}, trying next")
          try_stream_providers(rest, messages, callback, opts, errors ++ [{provider, reason}])
        else
          {:error, reason}
        end
    end
  rescue
    e ->
      Logger.warning(
        "[fallback] #{provider} stream crashed: #{Exception.message(e)}, trying next"
      )

      try_stream_providers(
        rest,
        messages,
        callback,
        opts,
        errors ++ [{provider, Exception.message(e)}]
      )
  end

  @doc """
  Check if an error is worth a cross-provider fallback attempt.

  Header-aware / classified (opencode `session/retry.ts` `retryable()`
  parity):

    * **Never** retried: context-window overflow. It is deterministic — the
      same-or-larger prompt fails against the next provider identically; only
      compaction can fix it (`RetryClassifier.context_overflow?/1`).
    * **Always** retried: 5xx server errors, overload, and rate-limit — these
      are provider-specific, so a *different* provider is likely fine.
    * Everything else falls back to the legacy substring classifier (kept as
      the fallback path for plain-string / unrecognized error shapes that
      carry no structured category — a provider crash message, for example).
  """
  @spec retryable_error?(term()) :: boolean()
  def retryable_error?(reason) do
    cond do
      RetryClassifier.context_overflow?(reason) ->
        false

      # A 404 / model-not-found is a CLEAR config error (bad /model pick),
      # not a transient fault — falling back to another provider silently
      # answers from a different model instead of surfacing the mistake.
      # Mirrors RetryClassifier's own `@fatal_categories` treatment of
      # :model_not_found; FallbackChain used to disagree via the substring
      # matcher below (finding #9).
      ErrorCatalog.classify(reason) == :model_not_found ->
        false

      # An auth failure is a CONFIG error, exactly like :model_not_found — the
      # user's key is wrong, missing, or revoked. Falling back to another
      # provider silently answers from a different model and hides the fact
      # that the key they just pasted was rejected.
      #
      # These categories were previously excluded only BY ACCIDENT: they are
      # absent from @always_retryable_categories, so they fell through to
      # substring_retryable?/1 and survived only because a 401 body happens not
      # to contain "timeout"/"connection"/"500"/... A provider whose 401
      # payload carries a request id like `req_5004a` matches the bare "500"
      # substring and would have been silently failed over.
      ErrorCatalog.classify(reason) in @auth_config_categories ->
        false

      ErrorCatalog.classify(reason) in @always_retryable_categories ->
        true

      is_binary(reason) ->
        substring_retryable?(reason)

      true ->
        substring_retryable?(Resilience.reason_to_string(reason))
    end
  end

  @doc """
  Server-directed `Retry-After` delay (ms) for a fallback-chain error reason,
  or `nil` when the reason carries none (the caller should fall back to its
  own fixed/backoff schedule). Mirrors opencode `retry.ts` `delay()` — a
  server directive, when present, always wins over a guessed backoff.
  """
  @spec retry_delay_ms(term()) :: non_neg_integer() | nil
  def retry_delay_ms(reason), do: RetryClassifier.reason_retry_after_ms(reason)

  defp substring_retryable?(reason) do
    reason_down = String.downcase(reason)

    Enum.any?(
      [
        "rate limit",
        "429",
        "overloaded",
        "503",
        "502",
        "500",
        "timeout",
        "connection",
        "unavailable",
        "capacity"
        # Deliberately NOT retryable: "404" / "not found" / "no such model" /
        # "unknown model" / "does not exist". A model-not-found is a clear
        # config error (bad /model pick) that will fail identically on every
        # other provider (or worse, silently answer from a different model)
        # — see the ErrorCatalog.classify == :model_not_found gate above,
        # which is now the authoritative check for this case (finding #9).
      ],
      fn pattern -> String.contains?(reason_down, pattern) end
    )
  end
end
