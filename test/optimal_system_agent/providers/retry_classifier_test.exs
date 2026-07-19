defmodule OptimalSystemAgent.Providers.RetryClassifierTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.RetryClassifier, as: RC

  @threshold RC.rate_limit_retry_threshold()

  # Generous budget so per-case budget exhaustion never masks the arm under test.
  @max 15

  describe "classify/4 — auth / session-owned errors" do
    test "401 emits to session (not a same-provider retry)" do
      err = {:http_error, 401, "invalid x-api-key"}
      assert {:emit_to_session, ^err} = RC.classify(err, 0, @max)
    end

    test "403 forbidden emits to session" do
      err = {:http_error, 403, "forbidden"}
      assert {:emit_to_session, ^err} = RC.classify(err, 0, @max)
    end

    test "revoked OAuth token emits to session" do
      err = "OAuth token has been revoked"
      assert {:emit_to_session, ^err} = RC.classify(err, 0, @max)
    end
  end

  describe "classify/4 — 413 / image errors → strip images" do
    test "413 Payload Too Large strips images" do
      assert :retry_with_image_strip = RC.classify({:http_error, 413, "too big"}, 0, @max)
    end

    test "image-processing 500 (proxy-wrapped) strips images, beating 5xx retry" do
      err = {:http_error, 500, "upstream: 400 Bad Request: Could not process image"}
      # A bare 500 is retryable; the image guard must intercept first.
      assert :retry_with_image_strip = RC.classify(err, 0, @max)
    end

    test "image dimensions error strips images" do
      err = {:http_error, 400, "image dimensions exceed max allowed size"}
      assert :retry_with_image_strip = RC.classify(err, 0, @max)
    end
  end

  describe "classify/4 — context overflow is fatal (fatal-to-compaction)" do
    test "context overflow dressed as a 500 is still fatal" do
      err = {:http_error, 500, "none: The prompt is too long for this model's context window."}
      assert {:fatal, ^err} = RC.classify(err, 0, @max)
    end

    test "context overflow as a 400 is fatal" do
      err = {:http_error, 400, "maximum context length exceeded"}
      assert {:fatal, ^err} = RC.classify(err, 0, @max)
    end

    test "plain-string token-limit overflow is fatal" do
      err = "This model's maximum context length is 200000 tokens"
      assert {:fatal, ^err} = RC.classify(err, 0, @max)
    end
  end

  describe "classify/4 — rate limiting (429)" do
    test "honors Retry-After seconds from the reason" do
      err = {:rate_limited, 7}
      assert {:retry_with_backoff, 7_000, true} = RC.classify(err, 0, @max)
    end

    test "falls back to jittered backoff when no Retry-After present" do
      err = {:rate_limited, nil}
      assert {:retry_with_backoff, backoff, true} = RC.classify(err, 0, @max)
      assert backoff >= 1_600 and backoff <= 2_400
    end

    test "429 via http_error shape is treated as rate-limited" do
      err = {:http_error, 429, "slow down"}
      assert {:retry_with_backoff, _backoff, true} = RC.classify(err, 0, @max)
    end

    test "capped at the rate-limit threshold" do
      err = {:rate_limited, 5}
      # retry_count = threshold-1 → next_attempt = threshold → fatal.
      assert {:fatal, ^err} = RC.classify(err, @threshold - 1, @max)
    end
  end

  describe "classify/4 — retryable 5xx / transport" do
    test "first 5xx rebuilds the HTTP client on HTTP/1.1" do
      err = {:http_error, 500, "boom"}
      assert {:retry_with_client_rebuild, backoff} = RC.classify(err, 0, @max)
      assert backoff >= 1_600 and backoff <= 2_400
    end

    test "5xx is retryable even for a status a strict SDK might refuse (520-style/plain 500)" do
      err = {:http_error, 502, "bad gateway"}
      assert {:retry_with_client_rebuild, _} = RC.classify(err, 0, @max)
    end

    test "second 5xx retry is a plain backoff (no rebuild)" do
      err = {:http_error, 503, "unavailable"}
      assert {:retry, backoff} = RC.classify(err, 1, @max)
      assert backoff >= 3_200 and backoff <= 4_800
    end

    test "5xx becomes fatal once the retry budget is exhausted" do
      err = {:http_error, 500, "boom"}
      assert {:fatal, ^err} = RC.classify(err, @max - 1, @max)
    end

    test "mid-stream error is retryable" do
      err = {:stream_error, "connection reset"}
      assert {:retry_with_client_rebuild, _} = RC.classify(err, 0, @max)
    end

    test "mid-stream error carrying tool_calls is NOT retried (double-exec guard)" do
      err = {:stream_error, "reset", %{tool_calls: [%{id: "t1"}]}}
      assert {:fatal, ^err} = RC.classify(err, 0, @max)
    end

    test "connection refused is retryable" do
      err = "econnrefused"
      assert {:retry_with_client_rebuild, _} = RC.classify(err, 0, @max)
    end
  end

  describe "classify/4 — fatal client errors" do
    test "400 invalid request is fatal" do
      err = {:http_error, 400, "Invalid model parameter"}
      assert {:fatal, ^err} = RC.classify(err, 0, @max)
    end

    test "404 model not found is fatal" do
      err = {:http_error, 404, "unknown model"}
      assert {:fatal, ^err} = RC.classify(err, 0, @max)
    end

    test "credit balance too low is fatal" do
      err = "Your credit balance is too low"
      assert {:fatal, ^err} = RC.classify(err, 0, @max)
    end
  end

  describe "backoff_with_jitter/1 — bounded exponential + jitter" do
    test "first retry is ~2s ±20%" do
      for _ <- 1..200 do
        b = RC.backoff_with_jitter(1)
        assert b >= 1_600 and b <= 2_400, "out of range: #{b}"
      end
    end

    test "second retry is ~4s ±20%" do
      for _ <- 1..200 do
        b = RC.backoff_with_jitter(2)
        assert b >= 3_200 and b <= 4_800
      end
    end

    test "caps at ~30s for large attempts" do
      for _ <- 1..200 do
        b = RC.backoff_with_jitter(10)
        assert b >= 24_000 and b <= 36_000
      end
    end

    test "attempt 0 stays in the base bucket and never panics" do
      b = RC.backoff_with_jitter(0)
      assert b >= 1_600 and b <= 2_400
    end

    test "very large attempts do not overflow past the cap" do
      b = RC.backoff_with_jitter(100)
      assert b >= 24_000 and b <= 36_000
    end
  end

  describe "parse_retry_after/1 — ms / seconds / HTTP-date" do
    test "millisecond form" do
      assert RC.parse_retry_after("1500ms") == 1_500
      assert RC.parse_retry_after("500 ms") == 500
    end

    test "delay-seconds form" do
      assert RC.parse_retry_after("30") == 30_000
    end

    test "integer seconds value" do
      assert RC.parse_retry_after(12) == 12_000
    end

    test "HTTP-date form yields a positive future delta" do
      future = DateTime.utc_now() |> DateTime.add(20, :second)
      header = format_http_date(future)
      ms = RC.parse_retry_after(header)
      assert is_integer(ms)
      # ~20s, allowing for clock/rounding slack.
      assert ms >= 17_000 and ms <= 20_000
    end

    test "a past HTTP-date yields nil (never a negative wait)" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second)
      assert RC.parse_retry_after(format_http_date(past)) == nil
    end

    test "unparseable / absent values yield nil" do
      assert RC.parse_retry_after("not-a-date") == nil
      assert RC.parse_retry_after(nil) == nil
      assert RC.parse_retry_after("0") == nil
      assert RC.parse_retry_after(-5) == nil
    end

    test "absurd values are capped at 60s" do
      assert RC.parse_retry_after("99999") == 60_000
      assert RC.parse_retry_after("120000ms") == 60_000
    end
  end

  # RFC 7231 IMF-fixdate, e.g. "Thu, 01 Jan 2026 00:00:30 GMT".
  defp format_http_date(dt) do
    dow = Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(dt) - 1)
    mon = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), dt.month - 1)

    p2 = fn n -> String.pad_leading(Integer.to_string(n), 2, "0") end

    "#{dow}, #{p2.(dt.day)} #{mon} #{dt.year} " <>
      "#{p2.(dt.hour)}:#{p2.(dt.minute)}:#{p2.(dt.second)} GMT"
  end
end
