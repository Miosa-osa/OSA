defmodule OptimalSystemAgent.Agent.Loop.StreamingToolExecutor do
  @moduledoc """
  Streaming tool executor — starts executing tools AS the LLM response streams.

  Instead of waiting for the full LLM response before executing any tools,
  this module detects complete tool_use blocks in the streaming callback and
  fires them immediately. By the time the full response arrives, some tools
  may already be complete.

  Architecture:
    - The LLM streaming callback calls `tool_block_complete/3` when a full
      tool_use block has been parsed (name + id + arguments).
    - This spawns the tool execution as a supervised Task.
    - `collect_results/1` waits for all in-flight tools to complete.
    - Results are returned in the same order as tool_calls for message assembly.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor

  @doc """
  Start a new streaming executor context.
  Returns an opaque ref to pass to tool_block_complete and collect_results.
  """
  def start(state) do
    %{
      state: state,
      in_flight: %{},     # tool_use_id => Task.t()
      completed: %{},     # tool_use_id => {tool_msg, result_str}
      order: []            # tool_use_ids in order received
    }
  end

  @doc """
  Called when a complete tool_use block is detected during streaming.
  Immediately fires the tool execution in a supervised Task.
  """
  def tool_block_complete(ctx, tool_call, state) do
    task =
      Task.Supervisor.async_nolink(
        OptimalSystemAgent.TaskSupervisor,
        fn ->
          ToolExecutor.execute_tool_call(tool_call, state)
        end
      )

    %{
      ctx
      | in_flight: Map.put(ctx.in_flight, tool_call.id, task),
        order: ctx.order ++ [tool_call.id]
    }
  end

  @doc """
  Wait for all in-flight tool executions to complete.
  Returns results in the same order as tool_calls were received.

  Timeout: 10 minutes per tool (matches existing orchestrator timeout).
  """
  def collect_results(ctx) do
    # Wait for all in-flight tasks
    results =
      Enum.reduce(ctx.in_flight, ctx.completed, fn {tool_id, task}, acc ->
        result =
          try do
            Task.await(task, 600_000)
          catch
            :exit, {:timeout, _} ->
              error_msg = %{role: "tool", tool_call_id: tool_id, content: "[Tool timed out after 10 minutes]"}
              {error_msg, "[timeout]"}
            :exit, reason ->
              error_msg = %{role: "tool", tool_call_id: tool_id, content: "[Tool crashed: #{inspect(reason)}]"}
              {error_msg, "[crash]"}
          end

        Map.put(acc, tool_id, result)
      end)

    # Return in order
    ctx.order
    |> Enum.map(fn tool_id -> Map.get(results, tool_id) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Check if there are any tools currently executing.
  """
  def has_in_flight?(ctx) do
    map_size(ctx.in_flight) > 0
  end

  @doc """
  Discard all in-flight results (used on fallback/retry).
  """
  def discard(ctx) do
    Enum.each(ctx.in_flight, fn {_id, task} ->
      Task.shutdown(task, :brutal_kill)
    end)

    %{ctx | in_flight: %{}, completed: %{}, order: []}
  end
end
