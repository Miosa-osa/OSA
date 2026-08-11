defmodule OptimalSystemAgent.Agent.Loop.CompactionBreakerTest do
  @moduledoc """
  The proactive-compaction circuit breaker had two defects that compound.

  **It latched permanently.** `should_compact?/2` gates on
  `not breaker_open?/1`; the breaker opens after 3 consecutive summarization
  failures; and `reset_failures/1` was called ONLY from the success branch of
  `compact/3` — which `should_compact?/2` will never route to again once open.
  No TTL, no probation, no decay. Three transient summary-LLM failures disabled
  proactive compaction for that session for the lifetime of the VM, after which
  the context grew unchecked to a hard provider overflow. The only escape was a
  manual `/compact`.

  **It was globally keyed.** The ETS key was
  `{:compact_failures, session_id || :global}`, so every caller without a
  session id — cron jobs, subagents, anonymous paths — shared a single counter
  and poisoned each other: three failures spread across three unrelated
  anonymous callers opened the breaker for all of them.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction, as: PC

  @probation_key :proactive_compaction_breaker_probation_ms

  setup do
    prev = Application.get_env(:optimal_system_agent, @probation_key)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, @probation_key)
        v -> Application.put_env(:optimal_system_agent, @probation_key, v)
      end
    end)

    :ok
  end

  defp fresh_session, do: "brk-#{System.unique_integer([:positive])}"

  defp open_breaker(session) do
    PC.reset_failures(session)
    Enum.each(1..3, fn _ -> PC.record_failure(session) end)
  end

  describe "the breaker opens on repeated failure" do
    test "three consecutive failures open it, fewer do not" do
      session = fresh_session()
      PC.reset_failures(session)

      refute PC.breaker_open?(session)

      PC.record_failure(session)
      refute PC.breaker_open?(session)

      PC.record_failure(session)
      refute PC.breaker_open?(session)

      PC.record_failure(session)
      assert PC.breaker_open?(session)

      PC.reset_failures(session)
    end

    test "a success closes it" do
      session = fresh_session()
      open_breaker(session)
      assert PC.breaker_open?(session)

      PC.reset_failures(session)
      refute PC.breaker_open?(session)
    end
  end

  describe "probation — the breaker can re-close without a success it cannot reach" do
    test "it re-closes for a trial once the probation window elapses" do
      # A 0ms window makes "the window has elapsed" true immediately; the point
      # under test is that elapsed time re-closes the breaker AT ALL, which is
      # what the old implementation could never do.
      Application.put_env(:optimal_system_agent, @probation_key, 0)

      session = fresh_session()
      open_breaker(session)

      refute PC.breaker_open?(session),
             "an elapsed probation window must allow one trial, otherwise the " <>
               "breaker can only ever be closed by a success it is blocking"

      PC.reset_failures(session)
    end

    test "it stays open for the whole probation window" do
      Application.put_env(:optimal_system_agent, @probation_key, 600_000)

      session = fresh_session()
      open_breaker(session)

      assert PC.breaker_open?(session),
             "probation must not be so eager that the breaker stops protecting anything"

      PC.reset_failures(session)
    end

    test "a failure during the trial re-arms the breaker for another window" do
      Application.put_env(:optimal_system_agent, @probation_key, 600_000)

      session = fresh_session()
      open_breaker(session)
      assert PC.breaker_open?(session)

      # Window elapses -> trial allowed.
      Application.put_env(:optimal_system_agent, @probation_key, 0)
      refute PC.breaker_open?(session)

      # The trial fails. The breaker must go back to protecting, not stay open
      # to an unbounded retry storm.
      PC.record_failure(session)
      Application.put_env(:optimal_system_agent, @probation_key, 600_000)

      assert PC.breaker_open?(session)

      PC.reset_failures(session)
    end
  end

  describe "per-session keying" do
    test "one session's failures do not open another session's breaker" do
      a = fresh_session()
      b = fresh_session()

      PC.reset_failures(a)
      PC.reset_failures(b)

      open_breaker(a)

      assert PC.breaker_open?(a)
      refute PC.breaker_open?(b), "sessions must not share a failure counter"

      PC.reset_failures(a)
      PC.reset_failures(b)
    end

    test "two id-less callers in different processes do not poison each other" do
      # The old key was `session_id || :global`: every anonymous caller shared
      # ONE counter, so three failures spread across three unrelated callers
      # opened the breaker for all of them.
      parent = self()

      # Caller A: three failures in its own process, then reports whether its
      # own breaker is open.
      task_a =
        Task.async(fn ->
          PC.reset_failures(nil)
          Enum.each(1..3, fn _ -> PC.record_failure(nil) end)
          send(parent, :a_failed)
          # Hold the process open so its identity stays distinct.
          receive do: (:done -> PC.breaker_open?(nil))
        end)

      assert_receive :a_failed, 2_000

      # Caller B: a different process that has failed zero times.
      task_b = Task.async(fn -> PC.breaker_open?(nil) end)

      refute Task.await(task_b, 2_000),
             "an id-less caller that never failed must not inherit another caller's failures"

      send(task_a.pid, :done)
      assert Task.await(task_a, 2_000), "the caller that DID fail must still be protected"
    end
  end
end
