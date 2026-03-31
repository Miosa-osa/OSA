defmodule OptimalSystemAgent.Providers.FallbackChain do
  @moduledoc """
  Fallback model chain — automatic provider switching on failure.

  When the primary provider fails (rate limit, downtime, error), tries
  the next provider in the chain. Configurable via:

      config :optimal_system_agent, :fallback_chain, [:anthropic, :openai, :groq, :ollama]

  Falls back silently — the agent continues working without interruption.
  """
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @default_chain [:anthropic, :openai, :groq, :ollama]

  @doc "Get the configured fallback chain."
  def chain do
    Application.get_env(:optimal_system_agent, :fallback_chain, @default_chain)
  end

  @doc """
  Try a chat call across the fallback chain.

  Starts with the given provider, falls back to the next on failure.
  Returns `{:ok, result, provider_used}` or `{:error, reason}` if all fail.
  """
  def chat_with_fallback(messages, opts \\ []) do
    primary = Keyword.get(opts, :provider) ||
      Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    # Build ordered chain: primary first, then configured fallbacks (excluding primary)
    fallback_providers = chain() |> Enum.reject(fn p -> p == primary end)
    ordered = [primary | fallback_providers]

    try_providers(ordered, messages, opts, [])
  end

  @doc """
  Try a streaming chat call across the fallback chain.

  Same as chat_with_fallback but for streaming calls.
  """
  def chat_stream_with_fallback(messages, callback, opts \\ []) do
    primary = Keyword.get(opts, :provider) ||
      Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    fallback_providers = chain() |> Enum.reject(fn p -> p == primary end)
    ordered = [primary | fallback_providers]

    try_stream_providers(ordered, messages, callback, opts, [])
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp try_providers([], _messages, _opts, errors) do
    error_summary = Enum.map(errors, fn {p, e} -> "#{p}: #{inspect(e)}" end) |> Enum.join("; ")
    {:error, "All providers failed: #{error_summary}"}
  end

  defp try_providers([provider | rest], messages, opts, errors) do
    opts_with_provider = Keyword.put(opts, :provider, provider)

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
    opts_with_provider = Keyword.put(opts, :provider, provider)

    case Providers.chat_stream(messages, callback, opts_with_provider) do
      {:ok, result} ->
        if errors != [] do
          Logger.info("[fallback] Stream succeeded with #{provider} after #{length(errors)} failure(s)")
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
      Logger.warning("[fallback] #{provider} stream crashed: #{Exception.message(e)}, trying next")
      try_stream_providers(rest, messages, callback, opts, errors ++ [{provider, Exception.message(e)}])
  end

  defp retryable_error?(reason) when is_binary(reason) do
    reason_down = String.downcase(reason)
    Enum.any?([
      "rate limit", "429", "overloaded", "503", "502", "500",
      "timeout", "connection", "unavailable", "capacity"
    ], fn pattern -> String.contains?(reason_down, pattern) end)
  end

  defp retryable_error?(_), do: true
end
