defmodule OptimalSystemAgent.Providers.RetryClassifier do
  @moduledoc """
  Header-aware, error-classified retry decisions for LLM requests.

  Ported from grok's `xai-grok-sampler/src/retry.rs` (`classify_error` →
  `RetryDecision`). This module is **pure**: it never sleeps, logs, performs
  I/O, or mutates state. `OptimalSystemAgent.Providers.Resilience` wraps it with
  the actual retry loop, and the `providers/*` call-sites perform the concrete
  side-effects a decision asks for (sleep, image-strip, HTTP/1.1 rebuild).

  ## Decisions

  `classify/4` maps a provider error reason to one of:

    * `{:retry, backoff_ms}` — transient transport / 5xx: back off and retry.
    * `{:retry_with_backoff, backoff_ms, rate_limited?}` — honor a server
      `Retry-After`; `rate_limited?` distinguishes 429s for telemetry.
    * `:retry_with_image_strip` — 413 Payload Too Large / image-processing
      rejection: drop inline images and retry once (not counted against the
      retry budget).
    * `{:retry_with_client_rebuild, backoff_ms}` — the **first** retryable
      transport/5xx failure: rebuild the HTTP client on HTTP/1.1 to escape a
      poisoned HTTP/2 connection pool, then retry.
    * `{:emit_to_session, reason}` — auth / credential errors the caller owns
      (re-auth, `/login`); not a same-provider retry.
    * `{:fatal, reason}` — no further retries. Includes **context-overflow**,
      which is deterministic (re-sending the same-or-larger payload always
      fails) and is therefore fatal *at this layer* even when the backend
      dresses it as a 500 — it surfaces up to the compaction path unchanged.

  ## Backoff

  Exponential `2s, 4s, 8s, …` capped at 30s with ±20% jitter to break up
  thundering-herd retry storms. A server-supplied `Retry-After` always wins
  over the computed backoff (capped at 60s — it is a directive, not a hint).

  ## Retry-After parsing

  `parse_retry_after/1` accepts the three shapes seen in the wild and returns
  **milliseconds**:

    * `"1500ms"` — explicit millisecond form (some proxies / rate-limiters)
    * `"30"` — RFC 7231 delay-seconds
    * `"Thu, 01 Jan 2026 00:00:30 GMT"` — RFC 7231 HTTP-date (delta from now)
  """

  alias OptimalSystemAgent.Providers.ErrorCatalog

  @typedoc "A pure retry decision. The caller performs the side-effect."
  @type decision ::
          {:retry, non_neg_integer()}
          | {:retry_with_backoff, non_neg_integer(), boolean()}
          | :retry_with_image_strip
          | {:retry_with_client_rebuild, non_neg_integer()}
          | {:emit_to_session, term()}
          | {:fatal, term()}

  # Cap consecutive 429 retries — rate-limit waits are long and burning a full
  # budget just to be rate-limited again is pointless (grok RATE_LIMIT_RETRY_THRESHOLD).
  @rate_limit_retry_threshold 2

  # Exponential backoff: base 2s, cap 30s, ±20% jitter (grok retry_backoff_with_jitter).
  @backoff_base_ms 2_000
  @backoff_cap_ms 30_000
  @jitter_fraction 5

  # A server Retry-After is honored as-is, capped so a hostile/absurd value
  # can't stall the agent indefinitely.
  @retry_after_cap_ms 60_000

  # Error categories (from ErrorCatalog) that are owned by the session /
  # credential layer rather than retried against the same provider.
  @auth_categories [
    :auth,
    :invalid_api_key,
    :token_revoked,
    :oauth_org_not_allowed,
    :org_disabled
  ]

  # Categories that mean "the request payload had an image the provider
  # rejected" — strip images and retry, same recovery as a 413.
  @image_categories [:request_too_large, :image_too_large]

  # Categories that are deterministically fatal at the HTTP-retry layer.
  # `:context_overflow` is fatal *here* on purpose: it is surfaced up so the
  # existing compaction path can shrink the prompt (fatal-to-compaction).
  @fatal_categories [
    :context_overflow,
    :credit_balance,
    :model_not_found,
    :invalid_request,
    :tool_use_mismatch,
    :duplicate_tool_use,
    :refusal,
    :pdf_too_large,
    :pdf_password_protected,
    :pdf_invalid,
    :ssl_error,
    :dns_error
  ]

  # Transient categories worth retrying against the same provider.
  @retryable_categories [
    :server_error,
    :server_overload,
    :rate_limit,
    :timeout,
    :connection_error
  ]

  @doc "The consecutive-429 retry cap."
  @spec rate_limit_retry_threshold() :: pos_integer()
  def rate_limit_retry_threshold, do: @rate_limit_retry_threshold

  @doc """
  True when `reason` is a context-window-overflow error — deterministically
  fatal (re-sending the same-or-larger prompt against ANY provider will fail
  the same way; only compaction fixes it). Public so cross-provider callers
  (`Providers.FallbackChain`) can exclude it from a fallback attempt too, not
  just the same-provider retry loop `classify/4` already guards.
  """
  @spec context_overflow?(term()) :: boolean()
  def context_overflow?(reason), do: do_context_overflow?(reason)

  @doc """
  Public accessor for the server-supplied `Retry-After` delay (in
  milliseconds) carried by a structured error reason (`{:rate_limited, secs}`,
  or a `{:stream_error, ...}` wrapping one), or `nil` when the reason carries
  none. Mirrors the private extraction `classify/4` uses internally for the
  same-provider retry loop; exposed so `Providers.FallbackChain` can honor the
  same server directive when switching providers instead of ignoring it.
  """
  @spec reason_retry_after_ms(term()) :: non_neg_integer() | nil
  def reason_retry_after_ms(reason), do: retry_after_ms(reason)

  @doc """
  Classify a provider error into a `t:decision/0`.

  `retry_count` is the number of retries already performed (0 on the first
  failure). `max_retries` is the total retry budget. `opts`:

    * `:rate_limit_threshold` — cap on consecutive 429 retries
      (default #{@rate_limit_retry_threshold}).
    * `:fail_fast_categories` — `ErrorCatalog` category atoms that must be
      treated as `{:fatal, reason}` regardless of how they'd normally
      classify — e.g. `:connection_error` for a strictly-local provider
      (Ollama not running): retrying `econnrefused` against localhost won't
      fix itself between attempts, so burn zero of the retry budget on it
      and surface the actionable error immediately (P1). Checked first, so
      it overrides every other category including auth/rate-limit.

  Pure: no sleep, no logging, no I/O. Order mirrors grok's `classify_error`:
  fail-fast override → auth → image-strip (413) → context-overflow/fatal →
  rate-limit → retryable.
  """
  @spec classify(term(), non_neg_integer(), non_neg_integer(), keyword()) :: decision()
  def classify(reason, retry_count, max_retries, opts \\ []) do
    threshold = Keyword.get(opts, :rate_limit_threshold, @rate_limit_retry_threshold)
    fail_fast_categories = Keyword.get(opts, :fail_fast_categories, [])
    category = category_of(reason)

    cond do
      # 0. Caller-supplied fail-fast override — never retried, no matter what
      #    category it would otherwise land in.
      category in fail_fast_categories ->
        {:fatal, reason}

      # 1. Auth / credential errors are session-owned (re-auth, /login).
      category in @auth_categories ->
        {:emit_to_session, reason}

      # 2. 413 / image-processing: strip inline images and retry once. Checked
      #    BEFORE the fatal/should-not-retry guards because stripping changes
      #    the payload, so a "don't retry" verdict on the original request does
      #    not apply to the stripped one.
      category in @image_categories or image_processing_error?(reason) ->
        :retry_with_image_strip

      # 3. Context-overflow is fatal at this layer even when the backend dresses
      #    it as a 500 (ErrorCatalog classifies 5xx by status first, so a
      #    prompt-too-long 500 reads as :server_error — detect it by message
      #    here). It is deterministic: re-sending the same-or-larger payload
      #    always fails. Surfaced up unchanged for the compaction path.
      do_context_overflow?(reason) ->
        {:fatal, reason}

      # 3b. Other deterministic client errors are fatal.
      category in @fatal_categories ->
        {:fatal, reason}

      # 4. Rate limited (429): cap retries at the threshold; honor Retry-After.
      category == :rate_limit or rate_limited?(reason) ->
        rate_limit_decision(reason, retry_count, max_retries, threshold)

      # 5. Generic retryable transport / 5xx (retried even if a provider SDK
      #    would call the 5xx non-retryable). First retry rebuilds the client
      #    on HTTP/1.1 to escape a poisoned HTTP/2 pool; later retries back off.
      category in @retryable_categories or stream_retryable?(reason) ->
        retryable_decision(reason, retry_count, max_retries)

      # 6. Everything else is fatal.
      true ->
        {:fatal, reason}
    end
  end

  defp rate_limit_decision(reason, retry_count, max_retries, threshold) do
    next_attempt = retry_count + 1
    effective_cap = min(max_retries, threshold)

    if next_attempt >= effective_cap do
      {:fatal, reason}
    else
      backoff = retry_after_ms(reason) || backoff_with_jitter(next_attempt)
      {:retry_with_backoff, backoff, true}
    end
  end

  defp retryable_decision(reason, retry_count, max_retries) do
    next_attempt = retry_count + 1

    if next_attempt >= max_retries do
      {:fatal, reason}
    else
      backoff = retry_after_ms(reason) || backoff_with_jitter(next_attempt)

      if next_attempt == 1 do
        {:retry_with_client_rebuild, backoff}
      else
        {:retry, backoff}
      end
    end
  end

  @doc """
  Exponential backoff with jitter, in **milliseconds**.

  `attempt` is 1-based (the number of the retry about to be performed). Base is
  `2s · 2^(attempt-1)` capped at 30s, then ±20% jitter is applied. `attempt`
  values ≤ 1 (including 0) all map to the base 2s bucket.
  """
  @spec backoff_with_jitter(integer()) :: non_neg_integer()
  def backoff_with_jitter(attempt) do
    shift = max(attempt - 1, 0)
    # Guard against overflow blowing past the cap for large shifts.
    base =
      if shift >= 16,
        do: @backoff_cap_ms,
        else: min(@backoff_base_ms * pow2(shift), @backoff_cap_ms)

    jitter_range = div(base, @jitter_fraction)

    # Symmetric jitter in [-jitter_range, +jitter_range].
    jitter = :rand.uniform(2 * jitter_range + 1) - 1 - jitter_range
    base + jitter
  end

  defp pow2(n), do: Bitwise.bsl(1, n)

  @doc """
  Parse a raw `Retry-After` header value into **milliseconds**, or `nil` when
  absent/unparseable. Accepts millisecond (`"1500ms"`), delay-seconds (`"30"`),
  and RFC 7231 HTTP-date (`"Thu, 01 Jan 2026 00:00:30 GMT"`) forms. The result
  is capped at #{@retry_after_cap_ms}ms.
  """
  @spec parse_retry_after(term()) :: non_neg_integer() | nil
  def parse_retry_after(nil), do: nil

  def parse_retry_after(value) when is_integer(value) and value > 0,
    do: min(value * 1_000, @retry_after_cap_ms)

  def parse_retry_after(value) when is_integer(value), do: nil

  def parse_retry_after(value) when is_binary(value) do
    trimmed = String.trim(value)
    down = String.downcase(trimmed)

    cond do
      String.ends_with?(down, "ms") ->
        parse_int_prefix(String.trim_trailing(down, "ms")) |> cap_ms()

      match?({_, ""}, Integer.parse(trimmed)) ->
        {secs, ""} = Integer.parse(trimmed)
        if secs > 0, do: min(secs * 1_000, @retry_after_cap_ms), else: nil

      true ->
        case parse_http_date(trimmed) do
          {:ok, dt} ->
            diff_ms = DateTime.diff(dt, DateTime.utc_now(), :millisecond)
            if diff_ms > 0, do: min(diff_ms, @retry_after_cap_ms), else: nil

          :error ->
            nil
        end
    end
  end

  def parse_retry_after(_), do: nil

  defp cap_ms(nil), do: nil
  defp cap_ms(ms) when ms > 0, do: min(ms, @retry_after_cap_ms)
  defp cap_ms(_), do: nil

  defp parse_int_prefix(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  # ── Retry-After extraction from OSA error reasons ─────────────────────────

  # OSA carries a parsed Retry-After (in seconds) only on the {:rate_limited, _}
  # shape; convert to ms and cap.
  defp retry_after_ms({:rate_limited, secs}) when is_integer(secs) and secs > 0,
    do: min(secs * 1_000, @retry_after_cap_ms)

  defp retry_after_ms({:stream_error, reason}), do: retry_after_ms(reason)
  defp retry_after_ms({:stream_error, reason, _partial}), do: retry_after_ms(reason)
  defp retry_after_ms(_), do: nil

  defp rate_limited?({:rate_limited, _}), do: true
  defp rate_limited?(_), do: false

  # ── Category resolution (delegates to the rich ErrorCatalog) ──────────────

  defp category_of(reason), do: ErrorCatalog.classify(reason)

  # Context-window overflow, detected by message text regardless of the HTTP
  # status the backend used to carry it (mirrors ErrorCatalog.context_overflow?).
  defp do_context_overflow?(reason) do
    text = reason_text(reason)

    String.contains?(text, "prompt is too long") or
      String.contains?(text, "context_length") or
      String.contains?(text, "maximum context length") or
      String.contains?(text, "exceed context limit") or
      String.contains?(text, "token limit")
  end

  # A 400 or proxy-wrapped 500 that actually complains about image processing
  # is recovered the same way as a 413: strip images and retry.
  defp image_processing_error?(reason) do
    text = reason_text(reason)

    String.contains?(text, "could not process image") or
      String.contains?(text, "image processing") or
      String.contains?(text, "failed to process image")
  end

  # A mid-stream error is retryable, EXCEPT when its partial already carried
  # tool_use blocks (retrying would double-execute side-effecting tools). This
  # mirrors Resilience.classify/1's tool-call suppression.
  defp stream_retryable?({:stream_error, _reason}), do: true

  defp stream_retryable?({:stream_error, _reason, partial}),
    do: not stream_partial_has_tool_calls?(partial)

  defp stream_retryable?(_), do: false

  defp stream_partial_has_tool_calls?(partial) when is_map(partial) do
    tool_calls = Map.get(partial, :tool_calls) || Map.get(partial, "tool_calls") || []
    is_list(tool_calls) and tool_calls != []
  end

  defp stream_partial_has_tool_calls?(_), do: false

  defp reason_text({:http_error, _status, msg}) when is_binary(msg), do: String.downcase(msg)
  defp reason_text({:stream_error, reason}), do: reason_text(reason)
  defp reason_text({:stream_error, reason, _partial}), do: reason_text(reason)
  defp reason_text(reason) when is_binary(reason), do: String.downcase(reason)
  defp reason_text(reason), do: String.downcase(inspect(reason))

  # ── RFC 7231 HTTP-date parsing (shared shape with openai_compat) ──────────

  @http_date_months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  defp parse_http_date(v) when is_binary(v) do
    pattern = ~r/\w{3},\s+(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT/i

    case Regex.run(pattern, v) do
      [_, day_s, month_s, year_s, hour_s, min_s, sec_s] ->
        with {day, ""} <- Integer.parse(day_s),
             {:ok, month} <- Map.fetch(@http_date_months, String.downcase(month_s)),
             {year, ""} <- Integer.parse(year_s),
             {hour, ""} <- Integer.parse(hour_s),
             {minute, ""} <- Integer.parse(min_s),
             {second, ""} <- Integer.parse(sec_s),
             {:ok, date} <- Date.new(year, month, day),
             {:ok, time} <- Time.new(hour, minute, second),
             {:ok, dt} <- DateTime.new(date, time) do
          {:ok, dt}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
