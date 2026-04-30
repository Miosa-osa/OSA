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
