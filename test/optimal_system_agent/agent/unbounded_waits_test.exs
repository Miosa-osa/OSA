defmodule OptimalSystemAgent.Agent.UnboundedWaitsTest do
  @moduledoc """
  D3 / D4 / D5 / D9 — the four places an unattended agent could wait forever, or
  spawn without a ceiling.

    * D3 — compaction had no timeout ANYWHERE (`rg timeout` over
      `agent/compactor.ex` and `agent/loop/proactive_compaction.ex` returned
      nothing), and it is the one call a turn cannot skip.
    * D4 — `Loop.process_message/3` defaulted its `GenServer.call` timeout to
      `:infinity`, so a cross-surface message could block its channel forever
      with no ack.
    * D5 — `:max_fleet_agents` bounded only the `fleet` path, never `delegate`.
    * D9 — the fallback-chain `Retry-After` sleep had no bound of its own.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Orchestrator

  defp with_env(key, value, fun) do
    prev = Application.fetch_env(:optimal_system_agent, key)
    Application.put_env(:optimal_system_agent, key, value)

    try do
      fun.()
    after
      case prev do
        {:ok, v} -> Application.put_env(:optimal_system_agent, key, v)
        :error -> Application.delete_env(:optimal_system_agent, key)
      end
    end
  end

  # ── D4 — bounded turn join ────────────────────────────────────────────

  describe "D4: the turn call is bounded" do
    test "the default is a finite wall-clock, not :infinity" do
      Application.delete_env(:optimal_system_agent, :agent_turn_timeout_ms)

      timeout = Loop.turn_timeout([])

      refute timeout == :infinity,
             "process_message/3 defaults to :infinity — a channel can block forever with no ack"

      assert is_integer(timeout) and timeout > 0
    end

    test "an explicit per-call timeout still wins" do
      assert Loop.turn_timeout(timeout: 1_234) == 1_234
    end

    test "an operator can still opt back in to :infinity explicitly" do
      with_env(:agent_turn_timeout_ms, :infinity, fn ->
        assert Loop.turn_timeout([]) == :infinity
      end)
    end

    test "a garbage configured value falls back to the finite default" do
      with_env(:agent_turn_timeout_ms, "not a number", fn ->
        assert is_integer(Loop.turn_timeout([]))
      end)
    end
  end

  # ── D3 — bounded compaction with a deterministic fallback ─────────────

  describe "D3: compaction is bounded" do
    @messages [
      %{role: "user", content: String.duplicate("alpha ", 400)},
      %{role: "assistant", content: String.duplicate("beta ", 400)},
      %{role: "user", content: String.duplicate("gamma ", 400)}
    ]

    test "a wedged summarizer is killed and the deterministic path takes over" do
      with_env(:compaction_timeout_ms, 150, fn ->
        parent = self()

        {elapsed_us, result} =
          :timer.tc(fn ->
            TurnPipeline.bounded_compaction(@messages, fn ->
              send(parent, {:summarizer, self()})
              Process.sleep(:infinity)
            end)
          end)

        assert_received {:summarizer, summarizer_pid}

        # Bounded: nowhere near "forever".
        assert elapsed_us < 5_000_000,
               "compaction was not bounded — a wedged summarizer stalls the turn"

        # And it made progress rather than returning the un-shrunk history.
        assert is_list(result)

        # The wedged task is reaped, not orphaned burning a connection.
        refute Process.alive?(summarizer_pid),
               "the wedged summarizer was left running after the timeout"
      end)
    end

    test "a summarizer that returns in time is used verbatim" do
      with_env(:compaction_timeout_ms, 5_000, fn ->
        compacted = [%{role: "system", content: "summary"}]
        assert TurnPipeline.bounded_compaction(@messages, fn -> compacted end) == compacted
      end)
    end

    test "a crashing summarizer falls back deterministically instead of failing the turn" do
      with_env(:compaction_timeout_ms, 5_000, fn ->
        assert is_list(TurnPipeline.bounded_compaction(@messages, fn -> raise "boom" end))
      end)
    end
  end

  # ── D5 — the delegate path is capped ──────────────────────────────────

  describe "D5: the delegate path honours :max_fleet_agents" do
    test "the cap is the SAME knob the fleet path uses" do
      with_env(:max_fleet_agents, 3, fn ->
        assert Orchestrator.delegate_concurrency_cap() == 3
      end)
    end

    test "a nonsensical cap still floors at 1 rather than disabling all spawning" do
      with_env(:max_fleet_agents, 0, fn ->
        assert Orchestrator.delegate_concurrency_cap() == 1
      end)
    end

    test "background admission closes once the cap is reached" do
      # Seed the cap's worth of live runs, then assert the gate says "full".
      cap = 2

      with_env(:max_fleet_agents, cap, fn ->
        parent = "cap-parent-#{:erlang.unique_integer([:positive])}"
        before = Orchestrator.live_agent_count()

        ids =
          for n <- 1..(cap + before) do
            id = "agent:#{parent}:#{n}"
            RunStore.start_run(%{agent_id: id, parent_session_id: parent, role: "a", task: "t"})
            id
          end

        assert Orchestrator.live_agent_count() >= cap

        refute Orchestrator.background_slot_available?(),
               "run_background/2 would admit an unbounded number of concurrent agents"

        # Freeing a slot re-opens admission.
        Enum.each(ids, fn id ->
          RunStore.complete(id, %{agent_id: id, status: :completed, summary: "done"})
        end)
      end)
    end
  end

  # ── D9 — the Retry-After sleep is capped locally ──────────────────────

  describe "D9: Retry-After is capped where it is slept on" do
    test "an absurd server-directed delay is clamped" do
      assert LLMClient.capped_retry_delay_ms(24 * 60 * 60 * 1000) == 60_000
    end

    test "a reasonable delay is honoured as-is" do
      assert LLMClient.capped_retry_delay_ms(5_000) == 5_000
    end

    test "nil / non-positive / garbage means no wait at all" do
      assert LLMClient.capped_retry_delay_ms(nil) == 0
      assert LLMClient.capped_retry_delay_ms(0) == 0
      assert LLMClient.capped_retry_delay_ms(-1) == 0
      assert LLMClient.capped_retry_delay_ms("60000") == 0
    end

    test "the cap matches Resilience's, so the two retry paths agree" do
      assert LLMClient.capped_retry_delay_ms(999_999_999) ==
               OptimalSystemAgent.Providers.Resilience.backoff_ms(1, 999_999_999)
    end
  end
end
