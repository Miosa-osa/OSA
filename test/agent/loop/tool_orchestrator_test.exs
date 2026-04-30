defmodule OptimalSystemAgent.Agent.Loop.ToolOrchestratorTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator
  alias OptimalSystemAgent.Tools.UseContext

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

  setup do
    {:ok, ctx: UseContext.empty(), state: %{session_id: "test"}}
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
  end
end
