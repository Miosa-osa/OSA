defmodule OptimalSystemAgent.Agent.Loop.ToolOrchestratorTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator
  alias OptimalSystemAgent.Tools.Registry
  alias OptimalSystemAgent.Tools.UseContext

  defmodule SafeTool do
    @moduledoc false
    def name, do: "test_safe_tool"
    def concurrency_safe?(_input, _ctx), do: true
  end

  defmodule UnsafeTool do
    @moduledoc false
    def name, do: "test_unsafe_tool"
    def concurrency_safe?(_input, _ctx), do: false
  end

  defmodule StubExecutor do
    @moduledoc false
    def execute_tool_call(tc, _state) do
      tool_msg = %{role: "tool", tool_call_id: tc.id, name: tc.name, content: "ok:#{tc.name}"}
      {tool_msg, "ok:#{tc.name}"}
    end
  end

  defmodule SlowStubExecutor do
    @moduledoc false
    def execute_tool_call(tc, _state) do
      Process.sleep(50)
      tool_msg = %{role: "tool", tool_call_id: tc.id, name: tc.name, content: "slow:#{tc.name}"}
      {tool_msg, "slow:#{tc.name}"}
    end
  end

  defmodule EventExecutor do
    @moduledoc false
    def execute_tool_call(tc, state) do
      pid = Map.fetch!(state, :test_pid)
      ref = Map.fetch!(state, :event_ref)

      send(pid, {:tool_event, ref, :started, tc.id, self()})
      Process.sleep(get_in(state, [:delays, tc.id]) || 0)
      send(pid, {:tool_event, ref, :finished, tc.id, self()})

      tool_msg = %{role: "tool", tool_call_id: tc.id, name: tc.name, content: "event:#{tc.id}"}
      {tool_msg, "event:#{tc.id}"}
    end
  end

  setup do
    builtin_tools = :persistent_term.get({Registry, :builtin_tools}, %{})
    supervisor = start_supervised!(Task.Supervisor)

    :persistent_term.put(
      {Registry, :builtin_tools},
      Map.merge(builtin_tools, %{
        SafeTool.name() => SafeTool,
        UnsafeTool.name() => UnsafeTool
      })
    )

    on_exit(fn ->
      :persistent_term.put({Registry, :builtin_tools}, builtin_tools)
    end)

    {:ok, ctx: UseContext.empty(), state: %{session_id: "test"}, supervisor: supervisor}
  end

  describe "partition/2" do
    test "splits unknown tools into the serial bucket (fail-closed)", %{ctx: ctx} do
      tcs = [
        %{id: "1", name: "definitely_not_registered_tool"}
      ]

      assert {[], [_]} = ToolOrchestrator.partition(tcs, ctx)
    end

    test "keeps order within each bucket", %{ctx: ctx} do
      tcs = [
        %{id: "a", name: "ghost_tool_1"},
        %{id: "b", name: "ghost_tool_2"},
        %{id: "c", name: "ghost_tool_3"}
      ]

      {_concurrent, serial} = ToolOrchestrator.partition(tcs, ctx)
      assert Enum.map(serial, & &1.id) == ["a", "b", "c"]
    end
  end

  describe "dispatch/3" do
    test "preserves original tool_call order in output", %{state: state} do
      tcs = [
        %{id: "1", name: "ghost_a"},
        %{id: "2", name: "ghost_b"},
        %{id: "3", name: "ghost_c"}
      ]

      results = ToolOrchestrator.dispatch(tcs, state, executor: StubExecutor)

      assert Enum.map(results, fn {tc, _r} -> tc.id end) == ["1", "2", "3"]
    end

    test "returns one result per tool_call", %{state: state} do
      tcs = [
        %{id: "1", name: "ghost_a"},
        %{id: "2", name: "ghost_b"}
      ]

      results = ToolOrchestrator.dispatch(tcs, state, executor: StubExecutor)
      assert length(results) == 2
    end

    test "result tuple shape is `{tool_call, {tool_msg, result_str}}`", %{state: state} do
      tcs = [%{id: "1", name: "ghost"}]
      [{tc, {msg, result_str}}] = ToolOrchestrator.dispatch(tcs, state, executor: StubExecutor)

      assert tc.id == "1"
      assert is_map(msg)
      assert msg.role == "tool"
      assert is_binary(result_str)
    end

    test "missing tool_calls produce 'Tool not executed' error", %{state: state} do
      # The orchestrator's executor stub returns successfully for all inputs,
      # so the missing-result path only triggers when an executor doesn't yield.
      # This test exercises the partition path with serial dispatch only.
      tcs = [%{id: "x", name: "unknown_tool"}]
      [{_tc, {_msg, result_str}}] = ToolOrchestrator.dispatch(tcs, state, executor: StubExecutor)
      # StubExecutor always returns ok, so this still succeeds — the
      # "Tool not executed" path is hit only on dispatch failure.
      assert result_str == "ok:unknown_tool"
    end

    test "handles empty tool_calls list", %{state: state} do
      assert [] = ToolOrchestrator.dispatch([], state, executor: StubExecutor)
    end

    test "unsafe calls are barriers before later safe calls", %{
      state: base_state,
      supervisor: supervisor
    } do
      ref = make_ref()

      state =
        Map.merge(base_state, %{
          test_pid: self(),
          event_ref: ref,
          delays: %{"safe1" => 50}
        })

      tcs = [
        %{id: "safe1", name: SafeTool.name()},
        %{id: "unsafe", name: UnsafeTool.name()},
        %{id: "safe2", name: SafeTool.name()}
      ]

      ToolOrchestrator.dispatch(tcs, state, executor: EventExecutor, supervisor: supervisor)

      events = collect_tool_events(ref, 6)

      assert event_index(events, :finished, "unsafe") < event_index(events, :started, "safe2")
    end

    test "adjacent safe calls still execute in a parallel batch", %{
      state: base_state,
      supervisor: supervisor
    } do
      ref = make_ref()

      state =
        Map.merge(base_state, %{
          test_pid: self(),
          event_ref: ref,
          delays: %{"safe1" => 200}
        })

      tcs = [
        %{id: "safe1", name: SafeTool.name()},
        %{id: "safe2", name: SafeTool.name()},
        %{id: "unsafe", name: UnsafeTool.name()}
      ]

      ToolOrchestrator.dispatch(tcs, state,
        executor: EventExecutor,
        max_concurrency: 2,
        supervisor: supervisor
      )

      events = collect_tool_events(ref, 6)

      assert event_index(events, :started, "safe2") < event_index(events, :finished, "safe1")
      assert event_index(events, :finished, "safe1") < event_index(events, :started, "unsafe")
    end

    # ── Result ordering under differential completion latency (regression) ──
    #
    # When the model requests N tools in one turn, the ones that are safe to
    # run in parallel are dispatched concurrently — nothing enforces that they
    # FINISH in the order they were REQUESTED. `dispatch/3` must still hand
    # `ReactLoop` results keyed to their own `tool_call_id` and sequenced in
    # the model's original request order, or a slow tool's result gets stamped
    # onto a faster tool's `tool_call_id` and the model reads tool A's output
    # as tool B's.
    test "a later-requested call finishing FIRST does not reorder or mis-key results", %{
      state: base_state,
      supervisor: supervisor
    } do
      ref = make_ref()

      state =
        Map.merge(base_state, %{
          test_pid: self(),
          event_ref: ref,
          # "1" is requested FIRST but is the slowest — "2" and "3" (requested
          # later) both finish well before it.
          delays: %{"1" => 200, "2" => 0, "3" => 0}
        })

      tcs = [
        %{id: "1", name: SafeTool.name()},
        %{id: "2", name: SafeTool.name()},
        %{id: "3", name: SafeTool.name()}
      ]

      results =
        ToolOrchestrator.dispatch(tcs, state, executor: EventExecutor, supervisor: supervisor)

      # Prove completion order really was reversed relative to request order —
      # otherwise this test would pass even under a naive positional zip.
      events = collect_tool_events(ref, 6)
      assert event_index(events, :finished, "2") < event_index(events, :finished, "1")
      assert event_index(events, :finished, "3") < event_index(events, :finished, "1")

      # The results array handed back to the model is still in the ORIGINAL
      # request order...
      assert Enum.map(results, fn {tc, _r} -> tc.id end) == ["1", "2", "3"]

      # ...and every result is matched to its OWN tool_call_id and body, never
      # the id of whichever call happened to land in that slot by arrival time.
      Enum.each(results, fn {tc, {tool_msg, result_str}} ->
        assert tool_msg.tool_call_id == tc.id
        assert tool_msg.content == "event:#{tc.id}"
        assert result_str == "event:#{tc.id}"
      end)
    end

    test "mixed parallel read-only calls + a serial barrier preserve request " <>
           "order and id-matching under differential delay",
         %{state: base_state, supervisor: supervisor} do
      ref = make_ref()

      state =
        Map.merge(base_state, %{
          test_pid: self(),
          event_ref: ref,
          # Within the trailing parallel batch (p2, p3), p3 is requested
          # SECOND but finishes FIRST.
          delays: %{"p1" => 0, "s1" => 0, "p2" => 200, "p3" => 0}
        })

      tcs = [
        %{id: "p1", name: SafeTool.name()},
        %{id: "s1", name: UnsafeTool.name()},
        %{id: "p2", name: SafeTool.name()},
        %{id: "p3", name: SafeTool.name()}
      ]

      results =
        ToolOrchestrator.dispatch(tcs, state, executor: EventExecutor, supervisor: supervisor)

      events = collect_tool_events(ref, 8)

      # p3 really did finish before p2 despite being requested after it...
      assert event_index(events, :finished, "p3") < event_index(events, :finished, "p2")

      # ...and the serial call is a genuine barrier: it starts only once p1 is
      # done, and both trailing parallel calls start only once IT is done.
      assert event_index(events, :finished, "p1") < event_index(events, :started, "s1")
      assert event_index(events, :finished, "s1") < event_index(events, :started, "p2")
      assert event_index(events, :finished, "s1") < event_index(events, :started, "p3")

      # Despite that, the returned results stay in ORIGINAL request order,
      # each matched to its own tool_call_id.
      assert Enum.map(results, fn {tc, _r} -> tc.id end) == ["p1", "s1", "p2", "p3"]

      Enum.each(results, fn {tc, {tool_msg, result_str}} ->
        assert tool_msg.tool_call_id == tc.id
        assert tool_msg.content == "event:#{tc.id}"
        assert result_str == "event:#{tc.id}"
      end)
    end
  end

  defp collect_tool_events(ref, count) do
    Enum.map(1..count, fn _ ->
      receive do
        {:tool_event, ^ref, event, id, _pid} ->
          {event, id}
      after
        1_000 -> flunk("timed out waiting for tool event #{inspect(ref)}")
      end
    end)
  end

  defp event_index(events, event, id) do
    Enum.find_index(events, &(&1 == {event, id}))
  end
end
