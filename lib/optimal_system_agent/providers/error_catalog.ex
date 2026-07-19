defmodule OptimalSystemAgent.Providers.ErrorCatalog do
  @moduledoc """
  Rich API error catalog — maps raw provider/API error reasons to stable
  categories and actionable user-facing messages (CC parity:
  `services/api/errors.ts` / `errorUtils.ts`).

  Understands the error shapes produced by the provider layer:

    * `{:rate_limited, retry_after_seconds | nil}`      — HTTP 429
    * `{:http_error, status, message}`
    * `{:stream_error, reason}` / `{:stream_error, reason, partial}`
    * plain strings (e.g. `"Anthropic returned 401: invalid x-api-key"`)

  `classify/1` returns a stable category atom (telemetry/analytics);
  `user_message/1` returns the actionable message shown to the user in place
  of the old canned "I encountered an error" string.
  """

  alias OptimalSystemAgent.Providers.Resilience

  @api_error_prefix "API Error"

  # Category → actionable user-facing message. Rate limits are formatted
  # separately because they carry a reset time.
  @messages %{
    context_overflow:
      "Prompt is too long · Run /compact to free context, or break the request into smaller parts.",
    credit_balance:
      "Credit balance is too low · Top up your provider account, or run /model to switch to a different provider.",
    missing_api_key:
      "No API key configured · Run `osa setup` (or /login) to add a provider key, then try again.",
    invalid_api_key:
      "Invalid or missing API key · Run /login to re-authenticate, or update the provider key in your settings.",
    token_revoked: "OAuth token revoked · Run /login to re-authenticate.",
    oauth_org_not_allowed:
      "Your organization does not allow OAuth for this tool · Run /login with a different account, or contact your administrator.",
    org_disabled:
      "This API key belongs to a disabled organization · Update or unset the configured API key (check environment variables and settings).",
    auth:
      "Authentication failed (401/403) · Run /login, or verify the provider API key in your settings.",
    model_not_found:
      "The selected model is unavailable (404 or unknown model) · Run /model to pick a different model.",
    request_too_large:
      "Request too large (413) · Remove large attachments or run /compact, then try again.",
    server_overload:
      "Provider overloaded (529) · Retries were exhausted — wait a moment and try again, or run /model to switch models.",
    server_error:
      "Provider server error (5xx) · Usually transient — try again; if it persists run /model to switch models.",
    invalid_request:
      "The provider rejected the request (400) · Try rephrasing, or run /model to switch models.",
    tool_use_mismatch:
      "Conversation history is out of sync (a tool call has no result) · Start a new session or /resume an earlier one.",
    duplicate_tool_use:
      "Conversation history is corrupted (duplicate tool call IDs) · Start a new session or /resume an earlier one.",
    image_too_large:
      "An image in the conversation is too large · Resize the image, or run /compact to drop old images from context.",
    pdf_too_large:
      "PDF too large for the API · Extract the text first (e.g. pdftotext) and try again.",
    pdf_password_protected:
      "The PDF is password protected · Unlock it or convert it to text first.",
    pdf_invalid: "The PDF file is not valid · Convert it to text first and try again.",
    refusal:
      "The provider declined this request (usage policy) · Try rephrasing the request or a different approach.",
    ssl_error:
      "SSL certificate error · If you are behind a corporate proxy or TLS-intercepting firewall, point SSL_CERT_FILE at your CA bundle.",
    timeout:
      "Request timed out · Check your internet connection and any proxy settings, then try again.",
    dns_error:
      "DNS lookup failed · Check your network connection and the provider base URL in your settings.",
    connection_error:
      "Unable to connect to the provider · Check your internet connection (and proxy settings), then try again."
  }

  @doc "All known category atoms."
  @spec categories() :: [atom()]
  def categories, do: [:rate_limit, :unknown | Map.keys(@messages)]

  @doc "Stable category atom for an error reason (parity with CC classifyAPIError)."
  @spec classify(term()) :: atom()
  def classify({:rate_limited, _retry_after}), do: :rate_limit
  def classify({:stream_error, reason}), do: classify(reason)
  def classify({:stream_error, reason, _partial}), do: classify(reason)

  def classify({:http_error, status, msg}) do
    classify_http(status, String.downcase(to_string_reason(msg)))
  end

  def classify(reason) when is_binary(reason), do: classify_string(String.downcase(reason))
  def classify(reason), do: classify_string(String.downcase(inspect(reason)))

  @doc """
  Actionable user-facing message for an error reason. Replaces the canned
  \"I encountered an error processing your request.\" string.
  """
  @spec user_message(term()) :: String.t()
  def user_message({:rate_limited, retry_after}) do
    reset_hint =
      if is_integer(retry_after) and retry_after > 0 do
        " · Resets in ~#{format_duration(retry_after)}"
      else
        ""
      end

    "#{@api_error_prefix}: Rate limited (429)#{reset_hint} · Wait for the reset, or run /model to switch models."
  end

  def user_message(reason) do
    case classify(reason) do
      :rate_limit ->
        user_message({:rate_limited, nil})

      :missing_api_key ->
        missing_api_key_message(reason)

      :model_not_found ->
        model_not_found_message(reason)

      :unknown ->
        "#{@api_error_prefix}: #{truncate(to_string_reason(reason), 300)} · Try again, or run /model to switch models."

      category ->
        "#{@api_error_prefix}: #{Map.fetch!(@messages, category)}"
    end
  end

  # ── HTTP-status classification ────────────────────────────────────────────

  defp classify_http(529, _down), do: :server_overload
  defp classify_http(429, _down), do: :rate_limit
  defp classify_http(413, _down), do: :request_too_large
  defp classify_http(404, _down), do: :model_not_found

  defp classify_http(status, down) when status in [401, 403] do
    cond do
      String.contains?(down, "revoked") ->
        :token_revoked

      String.contains?(down, "oauth authentication is currently not allowed") ->
        :oauth_org_not_allowed

      String.contains?(down, "x-api-key") or String.contains?(down, "invalid api key") ->
        :invalid_api_key

      true ->
        :auth
    end
  end

  defp classify_http(400, down) do
    case classify_string(down) do
      :unknown -> :invalid_request
      category -> category
    end
  end

  defp classify_http(status, down) when is_integer(status) and status >= 500 do
    if String.contains?(down, "overloaded"), do: :server_overload, else: :server_error
  end

  defp classify_http(_status, down), do: classify_string(down)

  # ── String classification (input is already downcased) ────────────────────
  # Order matters: specific, high-signal substrings first; generic status-code
  # sniffing last.
  defp classify_string(down) do
    cond do
      context_overflow?(down) ->
        :context_overflow

      String.contains?(down, "credit balance is too low") ->
        :credit_balance

      # No key configured locally (our own pre-flight error, e.g.
      # "ANTHROPIC_API_KEY not configured" / "API key not configured" /
      # "no api key"). Distinct from a 401 invalid-key: retrying will not help;
      # the user must add a key. Checked before the auth/invalid-key branches so
      # the message points at `osa setup` instead of "re-authenticate".
      missing_api_key?(down) ->
        :missing_api_key

      String.contains?(down, "oauth token has been revoked") ->
        :token_revoked

      String.contains?(down, "oauth authentication is currently not allowed") ->
        :oauth_org_not_allowed

      String.contains?(down, "organization has been disabled") ->
        :org_disabled

      String.contains?(down, "x-api-key") or String.contains?(down, "invalid api key") or
          String.contains?(down, "authentication_error") ->
        :invalid_api_key

      String.contains?(down, "invalid model name") or String.contains?(down, "model_not_found") or
          String.contains?(down, "not_found_error") or has_status?(down, 404) ->
        :model_not_found

      has_status?(down, 401) or has_status?(down, 403) or
          String.contains?(down, "unauthorized") or String.contains?(down, "forbidden") or
          String.contains?(down, "permission_error") ->
        :auth

      String.contains?(down, "overloaded") or has_status?(down, 529) ->
        :server_overload

      has_status?(down, 429) or String.contains?(down, "rate limit") or
          String.contains?(down, "rate-limit") or String.contains?(down, "rate_limit") ->
        :rate_limit

      has_status?(down, 413) or String.contains?(down, "request_too_large") ->
        :request_too_large

      String.contains?(down, "ids were found without") ->
        :tool_use_mismatch

      String.contains?(down, "ids must be unique") ->
        :duplicate_tool_use

      String.contains?(down, "image exceeds") or String.contains?(down, "image dimensions exceed") ->
        :image_too_large

      String.contains?(down, "pdf pages") ->
        :pdf_too_large

      String.contains?(down, "password protected") ->
        :pdf_password_protected

      String.contains?(down, "pdf specified was not valid") ->
        :pdf_invalid

      String.contains?(down, "usage policy") or String.contains?(down, "refusal") ->
        :refusal

      ssl_error?(down) ->
        :ssl_error

      String.contains?(down, "etimedout") or String.contains?(down, "timed out") or
          String.contains?(down, "timeout") or String.contains?(down, "went silent") ->
        :timeout

      String.contains?(down, "nxdomain") or String.contains?(down, "enotfound") ->
        :dns_error

      String.contains?(down, "econnrefused") or String.contains?(down, "econnreset") or
          String.contains?(down, "epipe") or String.contains?(down, "connection refused") or
          String.contains?(down, "connection failed") or
          String.contains?(down, "connection error") or String.contains?(down, "closed") ->
        :connection_error

      has_status?(down, 500) or has_status?(down, 502) or has_status?(down, 503) or
          has_status?(down, 504) or String.contains?(down, "internal server error") or
          String.contains?(down, "bad gateway") or String.contains?(down, "service unavailable") or
          String.contains?(down, "api_error") ->
        :server_error

      true ->
        :unknown
    end
  end

  # True when the reason describes a key that was never configured (as opposed
  # to a key the provider rejected). Matches our own pre-flight strings and the
  # common provider-agnostic phrasings.
  defp missing_api_key?(down) do
    String.contains?(down, "not configured") or String.contains?(down, "no api key") or
      String.contains?(down, "api key not set") or String.contains?(down, "api key is required") or
      String.contains?(down, "api key is missing") or String.contains?(down, "missing api key") or
      String.contains?(down, "api_key not configured")
  end

  # Actionable, source-aware message for a missing key. Names the exact env var
  # and provider when they can be recovered from the reason (e.g.
  # "ANTHROPIC_API_KEY not configured"), so the guidance is copy-pasteable,
  # matching the CC/grok pattern of listing every fix path.
  defp missing_api_key_message(reason) do
    text = to_string_reason(reason)

    case Regex.run(~r/([A-Z][A-Z0-9]*_API_KEY)/, text) do
      [_, env_var] ->
        provider = env_var |> String.replace_suffix("_API_KEY", "") |> humanize_provider()

        "#{@api_error_prefix}: No API key configured for #{provider} · Run `osa setup` " <>
          "(or /login), or set #{env_var}=…, then try again."

      _ ->
        "#{@api_error_prefix}: #{Map.fetch!(@messages, :missing_api_key)}"
    end
  end

  # Actionable, source-aware message for a model-not-found (404) error. Names
  # the offending provider when it can be recovered from the reason (e.g.
  # "Anthropic returned 404: ..."), so the user knows exactly which /model
  # pick was invalid instead of a generic 404 buried in an "All providers
  # failed" aggregate. Mirrors `missing_api_key_message/1`.
  defp model_not_found_message(reason) do
    text = to_string_reason(reason)

    provider =
      case Regex.run(~r/^(Anthropic|OpenAI|Groq|Ollama|DeepSeek|OpenRouter|Miosa|Google|Cohere|Mistral)\b/i, text) do
        [_, name] -> String.capitalize(name)
        nil -> nil
      end

    case provider do
      nil ->
        "#{@api_error_prefix}: #{Map.fetch!(@messages, :model_not_found)}"

      p ->
        "#{@api_error_prefix}: Model not found for #{p} (404) · Run /model to pick a valid model."
    end
  end

  defp humanize_provider("ANTHROPIC"), do: "Anthropic"
  defp humanize_provider("OPENAI"), do: "OpenAI"
  defp humanize_provider("OPENROUTER"), do: "OpenRouter"
  defp humanize_provider("OLLAMA"), do: "Ollama"
  defp humanize_provider("MIOSA"), do: "MIOSA"
  defp humanize_provider("GROQ"), do: "Groq"
  defp humanize_provider("DEEPSEEK"), do: "DeepSeek"
  defp humanize_provider("GOOGLE"), do: "Google"
  defp humanize_provider("COHERE"), do: "Cohere"
  defp humanize_provider("MISTRAL"), do: "Mistral"
  defp humanize_provider(other), do: other |> String.downcase() |> String.capitalize()

  defp context_overflow?(down) do
    String.contains?(down, "prompt is too long") or String.contains?(down, "context_length") or
      String.contains?(down, "maximum context length") or
      String.contains?(down, "exceed context limit") or String.contains?(down, "token limit")
  end

  defp ssl_error?(down) do
    String.contains?(down, "ssl") or String.contains?(down, "tls") or
      String.contains?(down, "certificate") or String.contains?(down, "cert_") or
      String.contains?(down, "self_signed") or String.contains?(down, "unable_to_verify")
  end

  defp has_status?(down, status), do: String.contains?(down, Integer.to_string(status))

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: Resilience.reason_to_string(reason)

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"

  defp format_duration(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    if m == 0, do: "#{h}h", else: "#{h}h #{m}m"
  end

  defp truncate(s, max) do
    if String.length(s) > max, do: String.slice(s, 0, max) <> "…", else: s
  end
end
