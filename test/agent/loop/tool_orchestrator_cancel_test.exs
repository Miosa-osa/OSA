defmodule OptimalSystemAgent.Agent.Loop.ToolOrchestratorCancelTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator

  @cancel_table :osa_cancel_flags

  defmodule HangingExecutor do
    @moduledoc false
    def execute_tool_call(tc, _state) do
      Process.sleep(10_000)
      {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: "done"}, "done"}
    end
  end

  setup do
    {:ok, supervisor: start_supervised!(Task.Supervisor)}
  end

  defp sid, do: "orch-cancel-#{System.unique_integer([:positive])}"

  test "pre-set cancel flag short-circuits execution with interrupted results", %{
    supervisor: supervisor
  } do
    session_id = sid()
    :ets.insert(@cancel_table, {session_id, true})
    on_exit(fn -> :ets.delete(@cancel_table, session_id) end)

    tcs = [%{id: "1", name: "ghost_a"}, %{id: "2", name: "ghost_b"}]

    results =
      ToolOrchestrator.dispatch(tcs, %{session_id: session_id},
        executor: HangingExecutor,
        supervisor: supervisor
      )

    assert length(results) == 2

    for {_tc, {msg, result_str}} <- results do
      assert result_str == "Error: Interrupted by user"
      assert msg.content == "Error: Interrupted by user"
    end
  end

  test "cancel mid-flight brutal-kills a hanging tool promptly", %{supervisor: supervisor} do
    session_id = sid()
    on_exit(fn -> :ets.delete(@cancel_table, session_id) end)

    spawn(fn ->
      Process.sleep(300)
      :ets.insert(@cancel_table, {session_id, true})
    end)

    started = System.monotonic_time(:millisecond)

    [{_tc, {_msg, result_str}}] =
      ToolOrchestrator.dispatch([%{id: "slow", name: "ghost_slow"}], %{session_id: session_id},
        executor: HangingExecutor,
        timeout_ms: 30_000,
        supervisor: supervisor
      )

    elapsed = System.monotonic_time(:millisecond) - started
    assert result_str == "Error: Interrupted by user"
    assert elapsed < 5_000
  end
end
