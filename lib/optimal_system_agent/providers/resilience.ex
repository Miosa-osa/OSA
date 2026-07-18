defmodule OptimalSystemAgent.Providers.Resilience do
  @moduledoc """
  Same-provider retry policy — the resilience layer that sits *below* the
  model/provider fallback chain.

  The ordering is deliberate:

    1. `Resilience.with_retry/2` retries the **same** provider a few times with
       exponential backoff (honoring a `Retry-After` when the provider supplies
       one). Only transient, retryable failures are retried.
    2. Only once same-provider retries are exhausted does the caller
       (`Providers.Registry`) fall back to an alternate model/provider.

  ## Retryable vs non-retryable

  Retried (transient / server-side): `408, 409, 429, 500, 502, 503, 504, 529`
  plus connection/timeout/overloaded/capacity errors and **mid-stream** SSE
  `error` events (`{:stream_error, _}`).

  Never retried (client-side / permanent): `400, 401, 403, 404`.

  ## Error shapes understood by `classify/1`

    * `{:rate_limited, retry_after_seconds | nil}` — HTTP 429
    * `{:http_error, status, message}`             — any HTTP status
    * `{:stream_error, reason}` / `{:stream_error, reason, partial}` — a
      streaming response that carried an `error` event mid-stream (distinct
      from a transport-level HTTP error)
    * a plain string (best-effort: scans for status codes / keywords)
  """

  require Logger

  @retryable_statuses [408, 409, 429, 500, 502, 503, 504, 529]
  @non_retryable_statuses [400, 401, 403, 404]

  # CC parity (services/api/withRetry.ts): 10 retries by default (11 total
  # attempts), overridable via OSA_API_MAX_RETRIES; 500ms base delay with
  # exponential growth capped at 32s plus 0-25% jitter. A server-supplied
  # Retry-After is a directive and is honored up to 60s.
  @default_max_retries 10
  @backoff_base_ms 500
  @backoff_cap_ms 32_000
  @retry_after_cap_ms 60_000

  # After this many consecutive overloaded (529) failures, stop retrying the
  # same provider so the caller can fall back to another model/provider
  # (CC MAX_529_RETRIES).
  @max_529_attempts 3

  @retryable_keywords ~w(
    overloaded rate\ limit rate-limit rate_limited timeout timed\ out
    unavailable capacity connection econnrefused closed reset
    temporarily service\ unavailable bad\ gateway gateway\ timeout
  )

  @doc "The HTTP statuses that trigger a same-provider retry."
  @spec retryable_statuses() :: [pos_integer()]
  def retryable_statuses, do: @retryable_statuses

  @doc "The HTTP statuses that must never be retried."
  @spec non_retryable_statuses() :: [pos_integer()]
  def non_retryable_statuses, do: @non_retryable_statuses

  @doc """
  Default maximum number of attempts: 1 initial + `OSA_API_MAX_RETRIES`
  retries (default #{@default_max_retries}).
  """
  @spec max_attempts() :: pos_integer()
  def max_attempts do
    retries =
      case System.get_env("OSA_API_MAX_RETRIES") do
        nil ->
          @default_max_retries

        value ->
          case Integer.parse(value) do
            {n, _} when n >= 0 -> n
            _ -> @default_max_retries
          end
      end

    retries + 1
  end

  @doc "True when the reason is an overloaded/529 capacity error."
  @spec overloaded?(term()) :: boolean()
  def overloaded?({:http_error, 529, _msg}), do: true

  def overloaded?({:http_error, _status, msg}) when is_binary(msg),
    do: String.contains?(msg, "overloaded_error")

  def overloaded?({:stream_error, reason}), do: overloaded?(reason)
  def overloaded?({:stream_error, reason, _partial}), do: overloaded?(reason)

  def overloaded?(reason) when is_binary(reason) do
    down = String.downcase(reason)
    String.contains?(down, "overloaded") or String.contains?(down, "529")
  end

  def overloaded?(_), do: false

  @doc """
  Classify an error reason.

  Returns `{:retry, retry_after_seconds | nil}` when the failure is transient
  and worth retrying against the same provider, or `:no_retry` otherwise.
  """
  @spec classify(term()) :: {:retry, non_neg_integer() | nil} | :no_retry
  def classify({:rate_limited, retry_after}), do: {:retry, retry_after}

  def classify({:http_error, status, _msg}) when status in @retryable_statuses, do: {:retry, nil}
  def classify({:http_error, status, _msg}) when status in @non_retryable_statuses, do: :no_retry
  def classify({:http_error, _status, _msg}), do: :no_retry

  # A streaming response that carried an `error` event mid-stream is normally
  # transient and worth retrying. BUT retrying re-invokes native_stream against
  # the SAME live callback: if the partial already delivered tool_use blocks,
  # the retry (a fresh API call with NEW tool ids that dedup can't catch) would
  # double-execute side-effecting tools. So we suppress the in-place retry ONLY
  # when the partial carries tool_calls, letting stream_with_fallback drop to
  # the sync same-provider attempt / provider fallback chain instead. Text-only
  # partials still retry (at worst a cosmetic duplicate prefix).
  def classify({:stream_error, _reason}), do: {:retry, nil}

  def classify({:stream_error, _reason, partial}) do
    if stream_partial_has_tool_calls?(partial), do: :no_retry, else: {:retry, nil}
  end

  def classify(reason) when is_binary(reason), do: classify_string(reason)
  def classify(_), do: :no_retry

  # Does the mid-stream partial already carry tool_use blocks? If so, a retry
  # would double-execute those tools. Text-only / string partials do not.
  defp stream_partial_has_tool_calls?(partial) when is_map(partial) do
    tool_calls = Map.get(partial, :tool_calls) || Map.get(partial, "tool_calls") || []
    is_list(tool_calls) and tool_calls != []
  end

  defp stream_partial_has_tool_calls?(_), do: false

  defp classify_string(reason) do
    down = String.downcase(reason)

    cond do
      # An explicit non-retryable status wins, unless a retryable status is also
      # present (defensive — a message shouldn't contain both).
      has_status?(reason, @non_retryable_statuses) and
          not has_status?(reason, @retryable_statuses) ->
        :no_retry

      has_status?(reason, @retryable_statuses) ->
        {:retry, nil}

      Enum.any?(@retryable_keywords, &String.contains?(down, &1)) ->
        {:retry, nil}

      true ->
        :no_retry
    end
  end

  defp has_status?(reason, statuses) do
    Enum.any?(statuses, &String.contains?(reason, Integer.to_string(&1)))
  end

  @doc """
  Compute the backoff delay (ms) before the next attempt.

  `attempt` is the 1-based number of the attempt that just failed. When the
  provider supplied a `Retry-After` (seconds), it is honored as-is (capped at
  #{@retry_after_cap_ms}ms, no jitter — it is a server directive); otherwise
  exponential backoff `#{@backoff_base_ms} * 2^(attempt-1)` capped at
  #{@backoff_cap_ms}ms, plus 0-25% random jitter to avoid thundering herds.
  """
  @spec backoff_ms(pos_integer(), non_neg_integer() | nil) :: non_neg_integer()
  def backoff_ms(attempt, retry_after \\ nil) do
    if is_integer(retry_after) and retry_after > 0 do
      min(retry_after * 1_000, @retry_after_cap_ms)
    else
      base = min(round(@backoff_base_ms * :math.pow(2, attempt - 1)), @backoff_cap_ms)
      jitter = :rand.uniform(div(base, 4) + 1) - 1
      base + jitter
    end
  end

  @doc """
  Run `fun` and retry the **same** provider on retryable failures.

  `fun` is a 0-arity function returning `{:ok, term}` | `:ok` (streaming) |
  `{:error, reason}`. Successful and non-retryable results are returned
  immediately. Retryable errors are retried with backoff until
  `:max_attempts` is reached, after which the last error is returned so the
  caller can fall back to an alternate provider.

  ## Options

    * `:max_attempts` — total attempts including the first (default
      `max_attempts/0`: 1 + `OSA_API_MAX_RETRIES` retries)
    * `:on_retry`     — `fn map -> any end` invoked *before* each backoff sleep.
      The map contains `:attempt`, `:next_attempt`, `:max_attempts`,
      `:delay_ms`, and `:reason`. Exceptions raised here are swallowed.
    * `:sleep`        — `fn ms -> any end` sleep function (default
      `Process.sleep/1`); injectable for tests.
  """
  @spec with_retry((-> term()), keyword()) :: term()
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_attempts = Keyword.get_lazy(opts, :max_attempts, &max_attempts/0)
    do_retry(fun, 1, max_attempts, opts, 0)
  end

  defp do_retry(fun, attempt, max_attempts, opts, overloaded_count) do
    result = fun.()

    case result do
      {:error, reason} when attempt < max_attempts ->
        overloaded_count =
          if overloaded?(reason), do: overloaded_count + 1, else: overloaded_count

        # Overloaded fallback (CC MAX_529_RETRIES): after 3 consecutive 529s
        # stop hammering this provider — return the error so the caller's
        # fallback chain can switch to another model/provider instead.
        if overloaded_count >= @max_529_attempts do
          Logger.warning(
            "[resilience] #{@max_529_attempts}x overloaded (529) — giving up on this provider so fallback can engage"
          )

          result
        else
          case classify(reason) do
            {:retry, retry_after} ->
              delay = backoff_ms(attempt, retry_after)
              notify_retry(opts, attempt, max_attempts, delay, reason)
              sleep_fn = Keyword.get(opts, :sleep, &Process.sleep/1)
              sleep_fn.(delay)
              do_retry(fun, attempt + 1, max_attempts, opts, overloaded_count)

            :no_retry ->
              result
          end
        end

      _ ->
        result
    end
  end

  defp notify_retry(opts, attempt, max_attempts, delay_ms, reason) do
    case Keyword.get(opts, :on_retry) do
      fun when is_function(fun, 1) ->
        try do
          fun.(%{
            attempt: attempt,
            next_attempt: attempt + 1,
            max_attempts: max_attempts,
            delay_ms: delay_ms,
            reason: reason
          })
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Best-effort conversion of an error reason to a human-readable string, safe
  for `Logger` interpolation (tuples would otherwise raise).
  """
  @spec reason_to_string(term()) :: String.t()
  def reason_to_string(reason) when is_binary(reason), do: reason
  def reason_to_string({:rate_limited, ra}), do: "rate-limited (retry-after: #{inspect(ra)})"
  def reason_to_string({:http_error, status, msg}), do: "HTTP #{status}: #{reason_to_string(msg)}"
  def reason_to_string({:stream_error, r}), do: "mid-stream error: #{reason_to_string(r)}"
  def reason_to_string({:stream_error, r, _partial}), do: "mid-stream error: #{reason_to_string(r)}"
  def reason_to_string(other), do: inspect(other)
end
