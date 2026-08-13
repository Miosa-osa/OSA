defmodule OptimalSystemAgent.Agent.Loop.ProactiveCompactionHooksTest do
  @moduledoc """
  Two deferred wirings in the proactive-compaction path.

  **Memory flush.** `Memory.Flush` was built, tested and wired to nothing. Its
  own `hook_contract/0` names the two call sites it needs; without them the
  harvest never ran, so every durable conclusion in a long session was folded
  into a lossy summary and lost.

  **Summarizer bound.** The summarize call had no timeout, so a wedged provider
  parked the compaction — and with it an unattended agent — indefinitely.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction
  alias OptimalSystemAgent.Memory.Flush

  defp sid, do: "hooks-#{System.unique_integer([:positive])}"

  defp put(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp restore(key, prev) do
    case prev do
      nil -> Application.delete_env(:optimal_system_agent, key)
      v -> Application.put_env(:optimal_system_agent, key, v)
    end
  end

  # ── hook_contract/0 is the authority ─────────────────────────────────────

  describe "Memory.Flush.hook_contract/0 is satisfied" do
    test "both documented call sites name functions that actually exist" do
      contract = Flush.hook_contract()

      assert %{before_compaction: before_c, after_compaction: after_c} = contract

      # before_compaction: `should_flush?/2` + `run/2`
      assert before_c.call =~ "Memory.Flush.should_flush?"
      assert before_c.call =~ "Memory.Flush.run"
      assert function_exported?(Flush, :should_flush?, 2)
      assert function_exported?(Flush, :run, 2)

      # after_compaction: `reset_cycle/1`
      assert after_c.call =~ "Memory.Flush.reset_cycle"
      assert function_exported?(Flush, :reset_cycle, 1)
    end

    test "the before_compaction hook is exposed by ProactiveCompaction" do
      # `function_exported?/3` answers false for a module that is merely not
      # LOADED yet, so without this the test reports a missing function
      # whenever compile order happens to leave the module unloaded — which is
      # a property of the build, not of the code under test.
      Code.ensure_loaded?(ProactiveCompaction)

      assert function_exported?(ProactiveCompaction, :maybe_flush, 2),
             "the :before_compaction hook must live in ProactiveCompaction, " <>
               "as hook_contract/0 specifies"
    end
  end

  # ── :before_compaction ───────────────────────────────────────────────────

  describe "maybe_flush/2 (the :before_compaction hook)" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :memory_flush_enabled)
      put(:memory_flush_enabled, true)
      on_exit(fn -> restore(:memory_flush_enabled, prev) end)
      :ok
    end

    test "claims the once-per-cycle latch when usage is inside the flush band" do
      window = 200_000
      session = sid()
      Flush.reset_cycle(session)

      state = %{
        last_input_tokens: Flush.flush_at(window),
        session_id: session,
        messages: [
          %{role: "user", content: "why did the build fail?"},
          %{
            role: "assistant",
            content: "The root cause was the stale symlink in the build directory."
          }
        ]
      }

      refute Flush.flushed?(session)

      assert ProactiveCompaction.maybe_flush(state, window) == state,
             "the hook is a side-effecting pass-through — state must be returned as-is"

      assert Flush.flushed?(session),
             "the flush hook never fired: the latch was not claimed"

      on_exit(fn -> Flush.reset_cycle(session) end)
    end

    test "does nothing below the flush band" do
      window = 200_000
      session = sid()
      Flush.reset_cycle(session)

      state = %{
        last_input_tokens: Flush.flush_at(window) - 1,
        session_id: session,
        messages: [%{role: "assistant", content: "The root cause was a stale symlink."}]
      }

      ProactiveCompaction.maybe_flush(state, window)

      refute Flush.flushed?(session),
             "flushing below the band would burn the cycle before the evidence exists"
    end

    test "does nothing at or above compact_at — that window belongs to compaction" do
      window = 200_000
      session = sid()
      Flush.reset_cycle(session)

      state = %{
        last_input_tokens: CompactionThresholds.compact_at(window),
        session_id: session,
        messages: [%{role: "assistant", content: "The root cause was a stale symlink."}]
      }

      ProactiveCompaction.maybe_flush(state, window)
      refute Flush.flushed?(session)
    end

    test "is idempotent within a cycle" do
      window = 200_000
      session = sid()
      Flush.reset_cycle(session)

      state = %{
        last_input_tokens: Flush.flush_at(window),
        session_id: session,
        messages: [%{role: "assistant", content: "The root cause was a stale symlink."}]
      }

      ProactiveCompaction.maybe_flush(state, window)
      assert Flush.flushed?(session)

      # Safe to call on every loop iteration in the band.
      assert ProactiveCompaction.maybe_flush(state, window) == state
      assert Flush.flushed?(session)

      on_exit(fn -> Flush.reset_cycle(session) end)
    end

    test "never raises, whatever the state shape" do
      assert ProactiveCompaction.maybe_flush(%{}, 200_000) == %{}
      assert ProactiveCompaction.maybe_flush(%{messages: nil}, nil) == %{messages: nil}
    end
  end

  # ── :after_compaction ────────────────────────────────────────────────────

  describe "compact/3 (the :after_compaction hook)" do
    setup do
      prev_llm = Application.get_env(:optimal_system_agent, :compactor_llm_enabled)
      prev_flush = Application.get_env(:optimal_system_agent, :memory_flush_enabled)

      # Stub summarizer — this describes the HOOK, not the summary quality.
      put(:compactor_llm_enabled, false)
      put(:memory_flush_enabled, true)

      on_exit(fn ->
        restore(:compactor_llm_enabled, prev_llm)
        restore(:memory_flush_enabled, prev_flush)
      end)

      :ok
    end

    defp bulky_history do
      # Enough turns/tokens to clear keep_turns and min_older_tokens so the
      # compaction actually reaches its success branch.
      filler = String.duplicate("context that must be compacted away. ", 400)

      for i <- 1..40,
          msg <- [
            %{role: "user", content: "step #{i}: #{filler}"},
            %{role: "assistant", content: "done #{i}: #{filler}"}
          ],
          do: msg
    end

    test "a successful compaction opens the next flush cycle" do
      session = sid()

      # Simulate a flush having already happened this cycle.
      assert :ok = Flush.begin(session)
      assert Flush.flushed?(session)

      messages = bulky_history()
      compacted = ProactiveCompaction.compact(messages, session, nil)

      assert length(compacted) < length(messages),
             "precondition: the compaction must actually have folded history"

      refute Flush.flushed?(session),
             "history was just folded — without reset_cycle/1 the latch stays claimed " <>
               "and the agent never flushes again for the rest of the session"
    end
  end

  # ── The summarizer bound, at a real call site ────────────────────────────

  describe "the summarize call is bounded" do
    @tag timeout: 30_000
    test "a wedged provider does not park the compaction" do
      prev_llm = Application.get_env(:optimal_system_agent, :compactor_llm_enabled)
      prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
      prev_sleep = Application.get_env(:optimal_system_agent, :mock_provider_sleep_ms)
      prev_timeout = Application.get_env(:optimal_system_agent, :summarizer_timeout_ms)
      prev_model = Application.get_env(:optimal_system_agent, :compaction_summarizer_model)

      put(:compactor_llm_enabled, true)
      put(:default_provider, :mock)
      # Pin the summarizer to :mock explicitly. `summarizer_opts/0` otherwise
      # falls through to the registry's resolved default, which a
      # concurrently-configured suite can leave pointing at a real provider.
      put(:compaction_summarizer_model, {:mock, "mock-model-1.0"})
      # 10 minutes: with no bound this call site never returns and the test
      # times out — which is precisely the unattended-agent stall.
      put(:mock_provider_sleep_ms, 600_000)
      put(:summarizer_timeout_ms, 150)

      on_exit(fn ->
        restore(:compactor_llm_enabled, prev_llm)
        restore(:default_provider, prev_provider)
        restore(:mock_provider_sleep_ms, prev_sleep)
        restore(:summarizer_timeout_ms, prev_timeout)
        restore(:compaction_summarizer_model, prev_model)
      end)

      messages = bulky_history()

      {elapsed_us, result} =
        :timer.tc(fn -> ProactiveCompaction.compact(messages, sid(), nil) end)

      assert result == messages,
             "on summarizer expiry the original history is returned untouched, so the " <>
               "caller can fall through to the reactive path without breaking the turn"

      assert elapsed_us < 20_000_000,
             "the summarize call must carry its own bound (took #{div(elapsed_us, 1000)}ms)"
    end
  end
end
