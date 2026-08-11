defmodule OptimalSystemAgent.Agent.CompactorSummarizerTimeoutTest do
  @moduledoc """
  The innermost summarizer calls used to invoke `Providers.Registry.chat/2`
  with no timeout at all.

  `TurnPipeline.bounded_compaction/2` (120s) contains a wedged summarizer from
  the OUTSIDE, but that is the turn's safety net, not this call's — and it only
  covers call sites reached through a turn. A provider stuck in a socket read
  therefore parked an unattended agent indefinitely on any path that did not go
  through the pipeline.

  `Compactor.bounded_chat/2` gives every innermost call its own, strictly
  smaller bound, so the inner bound fires first and the caller's own
  deterministic fallback runs.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor

  setup do
    prev = Application.get_env(:optimal_system_agent, :summarizer_timeout_ms)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, :summarizer_timeout_ms)
        v -> Application.put_env(:optimal_system_agent, :summarizer_timeout_ms, v)
      end
    end)

    :ok
  end

  describe "bounded_chat/2 is bounded" do
    test "a wedged provider call expires instead of hanging forever" do
      Application.put_env(:optimal_system_agent, :summarizer_timeout_ms, 120)

      prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
      prev_sleep = Application.get_env(:optimal_system_agent, :mock_provider_sleep_ms)

      Application.put_env(:optimal_system_agent, :default_provider, :mock)
      # Far longer than the bound: without a timeout this call never returns
      # inside the window and the assertion below would time out instead.
      Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, 30_000)

      on_exit(fn ->
        case prev_provider do
          nil -> Application.delete_env(:optimal_system_agent, :default_provider)
          v -> Application.put_env(:optimal_system_agent, :default_provider, v)
        end

        case prev_sleep do
          nil -> Application.delete_env(:optimal_system_agent, :mock_provider_sleep_ms)
          v -> Application.put_env(:optimal_system_agent, :mock_provider_sleep_ms, v)
        end
      end)

      {elapsed_us, result} =
        :timer.tc(fn ->
          Compactor.bounded_chat([%{role: "user", content: "summarize"}],
            provider: :mock,
            max_tokens: 16
          )
        end)

      assert result == {:error, :summarizer_timeout}

      assert elapsed_us < 5_000_000,
             "the call must return on its own bound, not on the provider's whim " <>
               "(took #{div(elapsed_us, 1000)}ms)"
    end

    test "the timeout error short-circuits the degenerate-summary retry" do
      # CompactionSafety.sample_with_retry/2 only re-samples DEGENERATE
      # summaries; it returns `{:error, reason}` verbatim. That is what routes a
      # timeout straight to the deterministic path instead of re-wedging on a
      # second attempt.
      alias OptimalSystemAgent.Agent.CompactionSafety

      calls = :counters.new(1, [])

      sampler = fn ->
        :counters.add(calls, 1, 1)
        {:error, :summarizer_timeout}
      end

      assert {:error, :summarizer_timeout} =
               CompactionSafety.sample_with_retry(sampler, max_attempts: 2)

      assert :counters.get(calls, 1) == 1,
             "a wedged summarizer must not be retried — that doubles the stall"
    end

    test "a healthy call still returns its result untouched" do
      Application.put_env(:optimal_system_agent, :summarizer_timeout_ms, 30_000)

      prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
      Application.put_env(:optimal_system_agent, :default_provider, :mock)

      on_exit(fn ->
        case prev_provider do
          nil -> Application.delete_env(:optimal_system_agent, :default_provider)
          v -> Application.put_env(:optimal_system_agent, :default_provider, v)
        end
      end)

      # `provider: :mock` explicitly, not just via :default_provider — the
      # registry resolves its default through a boot snapshot that a
      # concurrently-configured suite can leave pointing elsewhere.
      assert {:ok, %{}} =
               Compactor.bounded_chat([%{role: "user", content: "hi"}],
                 provider: :mock,
                 max_tokens: 16
               )
    end

    test "the default bound sits under the 120s outer bounded_compaction bound" do
      Application.delete_env(:optimal_system_agent, :summarizer_timeout_ms)

      inner = Application.get_env(:optimal_system_agent, :summarizer_timeout_ms, 90_000)
      outer = Application.get_env(:optimal_system_agent, :compaction_timeout_ms, 120_000)

      assert inner < outer,
             "the inner bound must fire FIRST so the caller's deterministic fallback runs, " <>
               "rather than the whole compaction being brutally killed from outside"
    end
  end
end
