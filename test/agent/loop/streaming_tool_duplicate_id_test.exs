defmodule OptimalSystemAgent.Agent.Loop.StreamingToolDuplicateIdTest do
  @moduledoc """
  P2 audit gap B (defensive half): `tool_block_complete/3` must refuse to
  start the same `tool_use` id a second time this turn, even if a duplicate
  event somehow reaches it — belt and suspenders alongside the stream-parse
  dedup in `providers/anthropic.ex` / `Providers.ToolCallDedup`.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.StreamingToolExecutor

  # Counts how many times each tool_call id actually ran.
  defmodule CountingExecutor do
    @moduledoc false
    def execute_tool_call(tc, state) do
      pid = Map.fetch!(state, :test_pid)
      send(pid, {:executed, tc.id})
      body = "ran #{tc.id}"
      {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: body}, body}
    end
  end

  defp call(id), do: %{id: id, name: "file_read", arguments: %{"path" => "/tmp/x"}}

  setup do
    {:ok, state: %{session_id: "test", tool_executor: CountingExecutor, test_pid: self()}}
  end

  test "a duplicate tool_use id is refused, not started a second time", %{state: state} do
    tc = call("dup_1")

    ctx =
      StreamingToolExecutor.start(state)
      |> StreamingToolExecutor.tool_block_complete(tc, state)
      |> StreamingToolExecutor.tool_block_complete(tc, state)

    results = StreamingToolExecutor.collect_results(ctx)

    # Only ONE execution reached the executor, no matter how many times
    # `tool_block_complete/3` was called for the same id.
    executed_ids =
      for _ <- 1..10 do
        receive do
          {:executed, id} -> id
        after
          0 -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    assert executed_ids == ["dup_1"]

    # `order` (and therefore the final tool_msgs list) carries the id ONCE.
    assert length(results) == 1
  end

  test "two DIFFERENT ids both start normally", %{state: state} do
    ctx =
      StreamingToolExecutor.start(state)
      |> StreamingToolExecutor.tool_block_complete(call("a"), state)
      |> StreamingToolExecutor.tool_block_complete(call("b"), state)

    results = StreamingToolExecutor.collect_results(ctx)

    executed_ids =
      for _ <- 1..10 do
        receive do
          {:executed, id} -> id
        after
          0 -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    assert Enum.sort(executed_ids) == ["a", "b"]
    assert length(results) == 2
  end

  test "a duplicate fired while the first is still in flight never starts a second task", %{
    state: state
  } do
    tc = call("dup_2")

    ctx =
      StreamingToolExecutor.start(state)
      |> StreamingToolExecutor.tool_block_complete(tc, state)

    # The guard must key on `:calls` (set at first dispatch, never pruned this
    # turn) — this is what a same-id duplicate arriving from a second
    # `{:tool_use_block, _}` callback event looks like.
    ctx = StreamingToolExecutor.tool_block_complete(ctx, tc, state)

    _ = StreamingToolExecutor.collect_results(ctx)

    assert_receive {:executed, "dup_2"}
    refute_receive {:executed, "dup_2"}, 200
  end
end
