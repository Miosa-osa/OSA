defmodule OptimalSystemAgent.Providers.FallbackChainTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.FallbackChain, as: FC

  describe "retryable_error?/1 — context-overflow is never retryable" do
    test "structured http_error context-length message → false" do
      err = {:http_error, 400, "This model's maximum context length is 200000 tokens"}
      refute FC.retryable_error?(err)
    end

    test "plain-string context-overflow message → false" do
      refute FC.retryable_error?("prompt is too long for this model")
    end

    test "even when dressed as a 500, context-overflow text still wins → false" do
      err = {:http_error, 500, "internal error: exceed context limit"}
      refute FC.retryable_error?(err)
    end
  end

  describe "retryable_error?/1 — always retry 5xx / overload / rate-limit" do
    test "structured 500 → true" do
      assert FC.retryable_error?({:http_error, 500, "internal server error"})
    end

    test "structured 503 → true" do
      assert FC.retryable_error?({:http_error, 503, "service unavailable"})
    end

    test "structured {:rate_limited, secs} → true" do
      assert FC.retryable_error?({:rate_limited, 30})
    end

    test "overloaded 529 → true" do
      assert FC.retryable_error?({:http_error, 529, "overloaded_error"})
    end
  end

  describe "retryable_error?/1 — substring classifier as fallback for plain strings" do
    test "binary reason mentioning 429 → true" do
      assert FC.retryable_error?("HTTP 429 rate limit exceeded")
    end

    test "binary reason mentioning 503 → true" do
      assert FC.retryable_error?("upstream returned 503")
    end

    test "unrelated binary reason → false" do
      refute FC.retryable_error?("some completely unrelated crash message")
    end
  end

  describe "retryable_error?/1 — structured-but-unrecognized reasons no longer default to true" do
    test "an auth error (structured) is not retried across providers" do
      refute FC.retryable_error?({:http_error, 401, "invalid x-api-key"})
    end

    test "nil reason is not retried" do
      refute FC.retryable_error?(nil)
    end
  end

  describe "retry_delay_ms/1 — header-aware delay parsing" do
    test "parses a rate_limited seconds count into ms" do
      assert FC.retry_delay_ms({:rate_limited, 5}) == 5_000
    end

    test "nil when the reason carries no Retry-After" do
      assert FC.retry_delay_ms({:http_error, 500, "boom"}) == nil
      assert FC.retry_delay_ms("plain string error") == nil
    end

    test "caps an absurd Retry-After at 60s" do
      assert FC.retry_delay_ms({:rate_limited, 10_000}) == 60_000
    end

    test "unwraps a stream_error carrying a rate_limited reason" do
      assert FC.retry_delay_ms({:stream_error, {:rate_limited, 2}}) == 2_000
    end
  end
end
