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

  ## Concurrency

  This is the loop's SECOND tool-dispatch site (`ToolOrchestrator` is the
  first), and only the Anthropic provider reaches it — `providers/anthropic.ex`
  is the sole emitter of `{:tool_use_block, _}`. It used to spawn every tool
  call as an unguarded Task, so a batched Anthropic turn ran all its tool calls
  fully concurrently. Two `file_edit` calls against one file are a
  read-modify-write race: last write wins, no error, and the model is told both
  landed. Reproduced against the real tool in
  `test/agent/loop/streaming_tool_concurrency_test.exs`.

  The decision of what may run alongside what is NOT re-implemented here. Each
  block asks `ToolOrchestrator.scope_of/2` — the same function
  `ToolOrchestrator.dispatch/3` uses — and the resulting `Tools.ConflictScope`
  is compared against every call already in flight:

    * a **parallel-safe** call starts as soon as any live barrier is done;
    * a **path-scoped** call (two `download`s, two `file_edit`s) waits only for
      the in-flight calls whose canonicalised targets it collides with — and
      starts immediately when they are disjoint;
    * a **barrier** waits for everything already in flight, and every later
      call waits for it.

  The eager-start property is preserved. Safe calls (reads, greps, globs, web
  fetches — the batches we actively want more of) still fire the instant their
  block finishes parsing, long before the assistant message completes. Only
  calls that would genuinely corrupt each other wait, and the wait happens
  INSIDE the spawned Task, so `tool_block_complete/3` never blocks the
  streaming callback.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop.ToolError
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator
  alias OptimalSystemAgent.Tools.ConflictScope

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
      # [{pid, ConflictScope.t()}] for every call fired this turn, newest first.
      # A new call waits on exactly those it conflicts with. Entries are not
      # pruned: monitoring an already-dead pid returns immediately, so a stale
      # entry costs one `:noproc` round-trip, and the list is bounded by the
      # number of tool calls in a single assistant turn.
      scopes: [],
      # tool_use_id => the tool_call map that was fired. Kept so an ERROR path
      # (idle timeout, dropped connection) can rebuild the assistant message
      # that owns these tool_use ids — without it, already-executed tool results
      # cannot be committed to history as a valid assistant/tool pair.
      calls: %{}
    }
  end

  @doc """
  Called when a complete tool_use block is detected during streaming.
  Fires the tool execution in a supervised Task immediately.

  "Immediately" means the Task is spawned immediately — this function never
  blocks the provider's streaming callback. Whether the Task *runs* immediately
  depends on `ToolOrchestrator.concurrency_safe?/2`: a concurrency-unsafe call
  waits inside its own Task for the calls already in flight. See the moduledoc.
  """
  def tool_block_complete(ctx, tool_call, state) do
    executor = executor_for(state)

    scope = scope_of(tool_call, state)
    in_flight = Map.get(ctx, :scopes, [])

    # Cross-call conflict, applied incrementally — the same decision
    # `ToolOrchestrator.execution_batches/2` makes on a complete list, reached
    # from the same code rather than a second copy of it. A `:barrier` conflicts
    # with everything in flight (the old "unsafe waits on open ++ barrier"); a
    # `:parallel` call conflicts only with barriers (the old "safe waits on the
    # barrier", now on ALL live barriers rather than the most recent one, which
    # is a strict correctness gain); a `:scoped` call waits only on the in-flight
    # calls whose canonicalised paths it actually collides with.
    predecessors =
      in_flight
      |> Enum.filter(fn {_pid, s} -> ConflictScope.conflict?(scope, s) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    if predecessors != [] do
      # Above debug on purpose. Every concurrency defect found in this loop so
      # far was silent, and "the model asked for two edits and got them one at
      # a time" is exactly the kind of thing whose absence from the logs made
      # the original bug invisible.
      Logger.info(
        "[streaming_tools] serialising #{tool_call.name} (#{tool_call.id}) behind " <>
          "#{length(predecessors)} in-flight call(s) — #{ConflictScope.describe(scope)}"
      )

      emit_serialized_telemetry(tool_call, state, scope, length(predecessors))
    end

    # Same process-boundary problem as ToolOrchestrator: `Cwd.get/0` reads the
    # process dictionary and a Task does not inherit one, so a tool spawned here
    # would default to the backend's boot directory rather than the session's
    # working_dir. Read on the caller, re-publish inside the Task.
    caller_cwd = OptimalSystemAgent.Workspace.Cwd.get()
    # …and the session identity, so `Settings.current_session/0` resolves inside
    # the Task and the session settings layer (`/add-dir`'s
    # `permissions.additionalDirectories`) is visible to the permission check.
    sid = Map.get(state, :session_id)

    task =
      Task.Supervisor.async_nolink(
        OptimalSystemAgent.TaskSupervisor,
        fn ->
          # Wait INSIDE the task, never in the caller: the caller is the agent
          # loop draining the provider's streaming mailbox, and blocking it
          # would stall the stream itself.
          await_predecessors(predecessors)
          OptimalSystemAgent.Workspace.Cwd.put_process_override(caller_cwd)
          if is_binary(sid) and sid != "", do: Process.put(:osa_session_id, sid)
          executor.execute_tool_call(tool_call, state)
        end
      )

    %{
      ctx
      | in_flight: Map.put(ctx.in_flight, tool_call.id, task),
        order: ctx.order ++ [tool_call.id],
        scopes: [{task.pid, scope} | in_flight],
        calls: Map.put(Map.get(ctx, :calls, %{}), tool_call.id, tool_call)
    }
  end

  # The loop's ONE concurrency decision, borrowed rather than copied. A raw
  # `state` map is all the streaming path has; the orchestrator accepts it and
  # builds the `UseContext` itself.
  #
  # Fail-closed on any failure: if the decision cannot be made, serialise. The
  # cost of a wrong `false` is latency; the cost of a wrong `true` is a lost
  # file.
  defp scope_of(tool_call, state) do
    ToolOrchestrator.scope_of(tool_call, state)
  rescue
    e ->
      Logger.warning(
        "[streaming_tools] concurrency check failed for #{inspect(Map.get(tool_call, :name))}: " <>
          "#{Exception.message(e)} — serialising"
      )

      %ConflictScope{mode: :barrier}
  catch
    :exit, _ -> %ConflictScope{mode: :barrier}
  end

  # Block until each predecessor task process has exited. `Process.monitor/1`
  # on an already-dead pid delivers `:DOWN` with `:noproc` straight away, so
  # this needs no timeout and cannot wedge on a predecessor that finished
  # before we got here. A predecessor that is brutal-killed (interrupt,
  # `discard/1`) also produces `:DOWN`, so a cancelled turn never leaves a
  # successor waiting forever.
  defp await_predecessors([]), do: :ok

  defp await_predecessors(pids) do
    Enum.each(pids, fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)
  end

  defp emit_serialized_telemetry(tool_call, state, scope, waiting_on) do
    reason =
      case scope do
        %ConflictScope{mode: :barrier} -> :unsafe
        %ConflictScope{mode: :scoped} -> :conflict
        # A parallel-safe call that still had to wait did so behind a barrier.
        _ -> :barrier
      end

    :telemetry.execute(
      [:osa, :tools, :serialized],
      %{count: 1, waiting_on: waiting_on},
      %{
        tool: Map.get(tool_call, :name),
        session_id: Map.get(state, :session_id),
        reason: reason,
        scope: ConflictScope.describe(scope),
        path: :streaming
      }
    )
  rescue
    _ -> :ok
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

    %{ctx | in_flight: %{}, completed: %{}, order: [], calls: %{}, scopes: []}
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
