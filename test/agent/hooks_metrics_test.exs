defmodule OptimalSystemAgent.Agent.HooksMetricsTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks

  # These tests verify the ETS-based metrics (replacing the old GenServer.cast path)

  describe "metrics/0 with ETS counters" do
    test "returns empty map when no hooks have run" do
      # Metrics accumulate across the test suite, but the structure must be correct
      metrics = Hooks.metrics()
      assert is_map(metrics)
    end

    test "metrics accumulate after run/2 calls" do
      payload = %{tool_name: "test_tool", arguments: %{}, session_id: "metrics_test"}

      # Run a few hooks — they'll increment ETS counters
      Hooks.run(:pre_tool_use, payload)
      Hooks.run(:pre_tool_use, payload)
      Hooks.run(:post_tool_use, Map.put(payload, :result, {:ok, "done"}))

      metrics = Hooks.metrics()

      # pre_tool_use should have at least 2 calls
      assert metrics[:pre_tool_use].calls >= 2
      assert metrics[:pre_tool_use].total_us >= 0
      assert metrics[:pre_tool_use].avg_us >= 0

      # post_tool_use should have at least 1 call
      assert metrics[:post_tool_use].calls >= 1
    end

    test "metrics track blocks" do
      # Register a blocking hook with a unique name
      hook_name = "metrics_blocker_#{:erlang.unique_integer([:positive])}"

      # Guarantee removal even if an assertion below fails mid-test — otherwise
      # this priority-1 blocker leaks into every later pre_tool_use hook run.
      on_exit(fn ->
        :ets.match_delete(Hooks.hooks_table_name(), {:pre_tool_use, hook_name, :_, :_, :_})
      end)

      Hooks.register(
        :pre_tool_use,
        hook_name,
        fn _payload ->
          {:block, "test block for metrics"}
        end, priority: 1)

      # Small sleep to let registration cast process
      Process.sleep(10)

      payload = %{tool_name: "test_tool", arguments: %{}, session_id: "metrics_block_test"}
      {:blocked, _} = Hooks.run(:pre_tool_use, payload)

      metrics = Hooks.metrics()
      assert metrics[:pre_tool_use].blocks >= 1

      # Clean up — remove the blocking hook so it doesn't affect other tests.
      # Row shape in the :osa_hooks bag is the 5-tuple {event, name, priority,
      # handler, opts}; the match pattern MUST have matching arity or nothing is
      # deleted and this priority-1 blocker leaks into every later pre_tool_use.
      :ets.match_delete(Hooks.hooks_table_name(), {:pre_tool_use, hook_name, :_, :_, :_})
    end

    test "metrics are readable concurrently" do
      # Spawn multiple processes reading metrics simultaneously
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            metrics = Hooks.metrics()
            assert is_map(metrics)
            :ok
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end
end
