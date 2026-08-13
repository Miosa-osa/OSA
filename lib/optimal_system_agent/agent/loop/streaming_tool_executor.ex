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

  alias OptimalSystemAgent.Agent.Loop.ToolError
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor

  @doc """
  Start a new streaming executor context.
  Returns an opaque ref to pass to tool_block_complete and collect_results.
  """
  def start(state) do
    %{
      state: state,
      # tool_use_id => Task.t()
      in_flight: %{},
      # tool_use_id => {tool_msg, result_str}
      completed: %{},
      # tool_use_ids in order received
      order: [],
      # tool_use_id => the tool_call map that was fired. Kept so an ERROR path
      # (idle timeout, dropped connection) can rebuild the assistant message
      # that owns these tool_use ids — without it, already-executed tool results
      # cannot be committed to history as a valid assistant/tool pair.
      calls: %{}
    }
  end

  @doc """
  Called when a complete tool_use block is detected during streaming.
  Immediately fires the tool execution in a supervised Task.
  """
  def tool_block_complete(ctx, tool_call, state) do
    executor = executor_for(state)

    task =
      Task.Supervisor.async_nolink(
        OptimalSystemAgent.TaskSupervisor,
        fn ->
          executor.execute_tool_call(tool_call, state)
        end
      )

    %{
      ctx
      | in_flight: Map.put(ctx.in_flight, tool_call.id, task),
        order: ctx.order ++ [tool_call.id],
        calls: Map.put(Map.get(ctx, :calls, %{}), tool_call.id, tool_call)
    }
  end

  @doc """
  Wait for all in-flight tool executions to complete.
  Returns results in the same order as tool_calls were received.

  **Unbounded by default.** This wrapper used to `Task.await(task, 600_000)`
  every tool call, so a fleet dispatch that legitimately runs for hours was
  killed at ten minutes and reported as a tool timeout — while the agents it
  launched carried on running in the background, invisible to the turn that
  started them. The turn lost its own work; nothing else stopped.

  A generic wrapper is the wrong place to enforce a duration. It cannot know
  whether it is wrapping a 200 ms file read or a multi-agent dispatch, so any
  single number it picks is both far too long for the first and far too short
  for the second. Tools that need a bound already carry their own: shell has a
  per-command timeout, the HTTP providers have receive timeouts, and
  `bounded_compaction/2` bounds the summarizer. Those are the layers that know
  what they are timing.

  Set `:tool_await_timeout_ms` to a positive integer to reimpose a ceiling
  (useful in tests); anything else means no limit. A wedged tool is still
  escapable — the turn is interruptible, which is the affordance that actually
  belongs to the user rather than to a constant.
  """
  def collect_results(ctx) do
    # Wait for all in-flight tasks
    results =
      Enum.reduce(ctx.in_flight, ctx.completed, fn {tool_id, task}, acc ->
        result =
          try do
            Task.await(task, await_timeout())
          catch
            # RESPOND-TO-MODEL (non-fatal tool error contract): a timeout or a
            # crashed tool task is a readable tool result, not a dead turn. The
            # "Error:" prefix is the convention finalize_result/Reminders/
            # DoomLoop key on — the old "[timeout]"/"[crash]" bodies were
            # invisible to every one of those checks.
            #
            # Only reachable when :tool_await_timeout_ms is configured; the
            # default no longer times out at all. The message reports the
            # configured bound rather than a hardcoded "10 minutes", which was
            # already a lie whenever the constant and the text drifted.
            :exit, {:timeout, _} ->
              failure(tool_id, "tool timed out after #{timeout_text()}")

            :exit, reason ->
              failure(tool_id, ToolError.exit_text(reason))
          end

        Map.put(acc, tool_id, result)
      end)

    # Return in order
    ctx.order
    |> Enum.map(fn tool_id -> Map.get(results, tool_id) end)
    |> Enum.reject(&is_nil/1)
  end

  # Executor seam, mirroring `ToolOrchestrator`'s `:executor` option: the loop
  # state may name the module that runs a tool call. Production never sets it
  # (so `ToolExecutor` is used); tests set it to count executions and prove a
  # drained tool is never run a second time.
  defp executor_for(state) when is_map(state), do: Map.get(state, :tool_executor) || ToolExecutor
  defp executor_for(_), do: ToolExecutor

  defp failure(tool_id, reason) do
    body = ToolError.model_text(reason)
    {%{role: "tool", tool_call_id: tool_id, content: body}, body}
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

    %{ctx | in_flight: %{}, completed: %{}, order: [], calls: %{}}
  end

  @doc """
  Drain an executor context into messages ready to append to conversation
  history: `{:ok, [assistant_msg | tool_msgs], executed_names}`, or `:none`
  when no tool ever started.

  This is the ERROR-path counterpart to the success path in `ReactLoop`.
  Tool_use blocks are executed EAGERLY as they stream, so by the time the
  connection goes idle the side effects have ALREADY happened (files written,
  commands run). Historically those results lived only in the process
  dictionary, which the error path never drained — so the work vanished and a
  retry would re-execute it (re-running a `git push`, rewriting a file).

  Committing them to history BEFORE the turn errors or retries is what makes a
  retry RESUME rather than replay: the rebuilt history already contains the
  assistant's tool_use blocks and their results, so the model never re-issues
  them.

  `partial_content` is whatever assistant text streamed before the failure; it
  becomes the content of the synthesized assistant message so the tool_use ids
  are owned by a real message and the API history stays valid.
  """
  @spec drain_to_messages(map() | nil, String.t() | nil) ::
          {:ok, [map()], [String.t()]} | :none
  def drain_to_messages(ctx, partial_content \\ "")

  def drain_to_messages(nil, _partial), do: :none

  def drain_to_messages(ctx, partial_content) do
    case Map.get(ctx, :order, []) do
      [] ->
        :none

      order ->
        results_by_id =
          ctx
          |> collect_results()
          |> Map.new(fn result ->
            tool_msg = elem(result, 0)
            {tool_msg[:tool_call_id] || tool_msg["tool_call_id"], tool_msg}
          end)

        calls = Map.get(ctx, :calls, %{})

        # Only ids we can attribute to a real tool_call are committed — a
        # tool result with no owning tool_use block would corrupt history.
        committed_ids = Enum.filter(order, &Map.has_key?(calls, &1))

        if committed_ids == [] do
          :none
        else
          tool_calls = Enum.map(committed_ids, &Map.fetch!(calls, &1))

          tool_msgs =
            Enum.map(committed_ids, fn id ->
              Map.get(results_by_id, id) ||
                %{
                  role: "tool",
                  tool_call_id: id,
                  content: ToolError.model_text("tool result lost")
                }
            end)

          content = if is_binary(partial_content), do: partial_content, else: ""

          assistant = %{role: "assistant", content: content, tool_calls: tool_calls}
          names = Enum.map(tool_calls, fn tc -> Map.get(tc, :name) || Map.get(tc, "name") end)

          {:ok, [assistant | tool_msgs], Enum.reject(names, &is_nil/1)}
        end
    end
  rescue
    e ->
      Logger.warning("[streaming_tools] drain failed: #{Exception.message(e)}")
      :none
  catch
    :exit, reason ->
      Logger.warning("[streaming_tools] drain exited: #{inspect(reason)}")
      :none
  end

  # No ceiling unless one is explicitly configured. See `collect_results/1`.
  defp await_timeout do
    case Application.get_env(:optimal_system_agent, :tool_await_timeout_ms, :infinity) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> :infinity
    end
  end

  defp timeout_text do
    case await_timeout() do
      :infinity -> "no limit"
      ms when ms >= 60_000 -> "#{div(ms, 60_000)} minutes"
      ms -> "#{div(ms, 1000)}s"
    end
  end

end
