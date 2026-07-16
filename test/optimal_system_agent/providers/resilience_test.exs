defmodule OptimalSystemAgent.Providers.ResilienceTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Resilience

  # A non-blocking sleep so retry tests run instantly.
  defp no_sleep, do: fn _ms -> :ok end

  describe "classify/1 — retryable HTTP statuses" do
    test "retries on all documented transient statuses" do
      for status <- [408, 409, 429, 500, 502, 503, 504, 529] do
        assert {:retry, _} = Resilience.classify({:http_error, status, "boom"}),
               "expected #{status} to be retryable"
      end
    end

    test "does NOT retry on client-error statuses" do
      for status <- [400, 401, 403, 404] do
        assert Resilience.classify({:http_error, status, "nope"}) == :no_retry,
               "expected #{status} to be non-retryable"
      end
    end

    test "unknown status codes are not retried (conservative default)" do
      assert Resilience.classify({:http_error, 418, "teapot"}) == :no_retry
    end
  end

  describe "classify/1 — rate limiting" do
    test "rate_limited surfaces the retry-after seconds" do
      assert Resilience.classify({:rate_limited, 30}) == {:retry, 30}
    end

    test "rate_limited with nil retry-after still retries" do
      assert Resilience.classify({:rate_limited, nil}) == {:retry, nil}
    end
  end

  describe "classify/1 — mid-stream errors" do
    test "a mid-stream error event routes to the retry path" do
      assert {:retry, nil} = Resilience.classify({:stream_error, "overloaded_error"})
    end

    test "mid-stream error carrying partial output still retries" do
      assert {:retry, nil} = Resilience.classify({:stream_error, "overloaded_error", "partial"})
    end
  end

  describe "classify/1 — string reasons (best effort)" do
    test "retries strings that embed a retryable status" do
      assert {:retry, nil} = Resilience.classify("Anthropic returned 503: overloaded")
    end

    test "does not retry strings that embed a client-error status" do
      assert :no_retry = Resilience.classify("Anthropic returned 400: bad request")
      assert :no_retry = Resilience.classify("Anthropic returned 401: unauthorized")
    end

    test "retries on connection / timeout / overloaded keywords" do
      assert {:retry, nil} = Resilience.classify("Anthropic connection failed: :econnrefused")
      assert {:retry, nil} = Resilience.classify("request timeout")
      assert {:retry, nil} = Resilience.classify("Overloaded")
    end

    test "does not retry an ordinary error string" do
      assert :no_retry = Resilience.classify("invalid tool schema")
    end
  end

  describe "classify/1 — fallthrough" do
    test "unknown terms are not retried" do
      assert Resilience.classify(:some_atom) == :no_retry
      assert Resilience.classify(nil) == :no_retry
    end
  end

  describe "backoff_ms/2" do
    test "honors retry-after (seconds → ms) when present" do
      assert Resilience.backoff_ms(1, 5) == 5_000
      assert Resilience.backoff_ms(3, 2) == 2_000
    end

    test "caps retry-after at 60s" do
      assert Resilience.backoff_ms(1, 9999) == 60_000
    end

    test "uses exponential backoff when no retry-after" do
      assert Resilience.backoff_ms(1) == 1_000
      assert Resilience.backoff_ms(2) == 2_000
      assert Resilience.backoff_ms(3) == 4_000
    end

    test "caps exponential backoff at 60s" do
      assert Resilience.backoff_ms(50) == 60_000
    end
  end

  describe "with_retry/2 — happy path" do
    test "returns success immediately without retrying" do
      assert {:ok, :done} = Resilience.with_retry(fn -> {:ok, :done} end, sleep: no_sleep())
    end

    test "passes through bare :ok (streaming success)" do
      assert :ok = Resilience.with_retry(fn -> :ok end, sleep: no_sleep())
    end
  end

  describe "with_retry/2 — retry behavior" do
    test "retries a retryable error up to max_attempts then returns last error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Resilience.with_retry(
          fn ->
            Agent.update(counter, &(&1 + 1))
            {:error, {:http_error, 503, "overloaded"}}
          end,
          sleep: no_sleep()
        )

      assert result == {:error, {:http_error, 503, "overloaded"}}
      # 1 initial + 2 retries = 3 total attempts.
      assert Agent.get(counter, & &1) == 3
    end

    test "succeeds on a later attempt after transient failures" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Resilience.with_retry(
          fn ->
            n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            if n < 3, do: {:error, {:http_error, 500, "server"}}, else: {:ok, :recovered}
          end,
          sleep: no_sleep()
        )

      assert result == {:ok, :recovered}
      assert Agent.get(counter, & &1) == 3
    end

    test "does NOT retry a non-retryable error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        Resilience.with_retry(
          fn ->
            Agent.update(counter, &(&1 + 1))
            {:error, {:http_error, 400, "bad"}}
          end,
          sleep: no_sleep()
        )

      assert result == {:error, {:http_error, 400, "bad"}}
      assert Agent.get(counter, & &1) == 1
    end

    test "respects a custom :max_attempts" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Resilience.with_retry(
        fn ->
          Agent.update(counter, &(&1 + 1))
          {:error, {:rate_limited, nil}}
        end,
        sleep: no_sleep(),
        max_attempts: 5
      )

      assert Agent.get(counter, & &1) == 5
    end
  end

  describe "with_retry/2 — on_retry callback" do
    test "invokes on_retry before each backoff with attempt metadata" do
      {:ok, events} = Agent.start_link(fn -> [] end)

      on_retry = fn info -> Agent.update(events, &[info | &1]) end

      Resilience.with_retry(
        fn -> {:error, {:rate_limited, 2}} end,
        sleep: no_sleep(),
        on_retry: on_retry
      )

      captured = Agent.get(events, & &1) |> Enum.reverse()
      # 2 retries → 2 notifications.
      assert length(captured) == 2

      first = hd(captured)
      assert first.attempt == 1
      assert first.next_attempt == 2
      assert first.max_attempts == 3
      # retry-after of 2s → 2000ms delay surfaced to the callback.
      assert first.delay_ms == 2_000
      assert first.reason == {:rate_limited, 2}
    end

    test "an exception raised inside on_retry does not break the retry loop" do
      result =
        Resilience.with_retry(
          fn -> {:error, {:http_error, 502, "bad gateway"}} end,
          sleep: no_sleep(),
          on_retry: fn _ -> raise "boom" end
        )

      assert result == {:error, {:http_error, 502, "bad gateway"}}
    end
  end

  describe "reason_to_string/1" do
    test "renders tuple reasons as safe strings" do
      assert Resilience.reason_to_string({:rate_limited, 30}) =~ "rate-limited"
      assert Resilience.reason_to_string({:http_error, 500, "oops"}) =~ "HTTP 500"
      assert Resilience.reason_to_string({:stream_error, "overloaded"}) =~ "mid-stream"
      assert Resilience.reason_to_string({:stream_error, "overloaded", "partial"}) =~ "mid-stream"
      assert Resilience.reason_to_string("plain") == "plain"
    end
  end
end
