defmodule OptimalSystemAgent.Agent.Loop.ReactLoop do
  @moduledoc """
  Core ReAct iteration logic for the agent loop.

  Implements the bounded Reason-Act cycle:
  1. Check cancel flag and iteration budget
  2. Build context (with frozen system-prompt cache)
  3. Inject memory on first iteration
  4. Inject iteration budget message
  5. Call LLM via `LLMClient.llm_chat_stream/3`
  6. Handle result:
     - No tool calls → apply behavioural nudges or return final response
     - Tool calls    → execute in parallel, run doom-loop detection, recurse
     - Error         → compact and retry up to 3 times

  All state is immutable and passed through explicit arguments.
  The `run/1` and helper functions are pure (aside from ETS, Process dict,
  and side-effect calls that are clearly labelled).
  """
  require Logger

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Scratchpad
  alias OptimalSystemAgent.Agent.Loop.StreamingToolExecutor
  alias OptimalSystemAgent.Events.Bus

  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator
  alias OptimalSystemAgent.Agent.Loop.DoomLoop
  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.FastPath

  @cancel_table :osa_cancel_flags

  defp max_iterations do
    configured =
      Application.get_env(:optimal_system_agent, :max_iterations, Effort.max_iterations())

    min(configured, Effort.max_iterations())
  end

  defp max_response_tokens do
    # Check for bumped max_tokens from output token recovery.
    # Default raised from 8K → 32K so OSA can produce longer, more detailed
    # responses without truncation by default. Override via:
    #   config :optimal_system_agent, :max_response_tokens, <int>
    # if a provider's ceiling is tighter (e.g. some Ollama cloud models).
    Process.get(:osa_bumped_max_tokens) ||
      min(
        Application.get_env(:optimal_system_agent, :max_response_tokens, 32_768),
        Effort.max_response_tokens()
      )
  end

  @doc """
  Run the agent loop for the given state.

  Returns `{response_string, updated_state}`.
  """
  @spec run(map()) :: {String.t(), map()}
  def run(%{iteration: iter, session_id: sid} = state) do
    cancelled? =
      try do
        case :ets.lookup(@cancel_table, sid) do
          [{^sid, true}] -> true
          _ -> false
        end
      rescue
        ArgumentError -> false
      end

    max_iter = max_iterations()

    cond do
      cancelled? ->
        Logger.info("[loop] Cancelled by user at iteration #{iter}")
        :ets.delete(@cancel_table, sid)

        Bus.emit(:system_event, %{
          event: :agent_cancelled,
          session_id: sid,
          iteration: iter
        })

        {"Cancelled by user.", state}

      iter >= max_iter ->
        Logger.warning("Agent loop hit max iterations (#{max_iter}) for session #{sid}")
        tools_used = Telemetry.extract_tools_used(state.messages) |> Enum.join(", ")

        {"I've used all #{max_iter} iterations on this task.\n\n**Tools used:** #{tools_used}\n\nIf the task isn't complete, try breaking it into smaller steps or giving more specific instructions.",
         state}

      true ->
        do_iteration(state)
    end
  end

  # --- Private ---

  defp do_iteration(state) do
    Logger.debug(
      "[loop] do_iteration entered for #{state.session_id}, iteration=#{state.iteration}"
    )

    # Start async prefetches while we build context. In fast mode this also
    # grabs cheap workspace/git hints so the first model call is less blind.
    fast_prefetch_task = FastPath.prefetch_async(state)

    # Start async memory prefetch on iteration 0 (fires search while we build context)
    memory_task =
      if state.iteration == 0 do
        Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
          try do
            OptimalSystemAgent.Memory.Synthesis.search_relevant(state.messages)
          rescue
            _ -> nil
          end
        end)
      else
        nil
      end

    context = cached_context(state)
    Logger.debug("[loop] context built, #{length(context.messages)} messages")
    context = FastPath.inject_context(context, FastPath.await_prefetch(fast_prefetch_task))

    # Consume prefetched memory (waits max 2s, falls back to sync if timeout)
    context =
      if memory_task do
        case Task.yield(memory_task, 2_000) || Task.shutdown(memory_task, :brutal_kill) do
          {:ok, memories} when is_list(memories) and memories != [] ->
            inject_prefetched_memory(context, memories)

          _ ->
            maybe_inject_memory(context, state)
        end
      else
        maybe_inject_memory(context, state)
      end

    context = inject_pending_agent_messages(context, state)
    context = inject_iteration_budget(context, state)

    max_iter = max_iterations()

    Logger.debug(
      "[loop] About to call LLM for #{state.session_id}, iteration #{state.iteration + 1}/#{max_iter}"
    )

    Bus.emit(:llm_request, %{
      session_id: state.session_id,
      iteration: state.iteration,
      agent: state.session_id
    })

    start_time = System.monotonic_time(:millisecond)
    thinking_opts = LLMClient.thinking_config(state)
    tools_for_call = ToolFilter.filter(state.tools, state)

    llm_opts = [
      tools: tools_for_call,
      temperature: LLMClient.temperature(),
      max_tokens: max_response_tokens()
    ]

    llm_opts =
      if thinking_opts, do: Keyword.put(llm_opts, :thinking, thinking_opts), else: llm_opts

    # Initialize streaming tool executor — tools can start running mid-stream
    streaming_ctx = StreamingToolExecutor.start(state)
    Process.put(:osa_streaming_tool_ctx, streaming_ctx)

    result = LLMClient.llm_chat_stream(state, context.messages, llm_opts)

    # Collect any streaming tool blocks that arrived during the LLM call
    streaming_ctx =
      drain_streaming_tool_blocks(Process.get(:osa_streaming_tool_ctx, streaming_ctx), state)

    Process.put(:osa_streaming_tool_ctx, streaming_ctx)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    usage =
      case result do
        {:ok, resp} -> Map.get(resp, :usage, %{})
        _ -> %{}
      end

    input_tokens = Map.get(usage, :input_tokens, 0)
    state = if input_tokens > 0, do: %{state | last_input_tokens: input_tokens}, else: state

    Bus.emit(:llm_response, %{
      session_id: state.session_id,
      provider: state.provider,
      duration_ms: duration_ms,
      usage: usage,
      agent: state.session_id
    })

    Logger.info("[loop] LLM call completed in #{duration_ms}ms (#{input_tokens} input tokens)")

    handle_result(result, state, context)
  end

  # Max tokens recovery — response was truncated, bump limit and retry
  defp handle_result({:ok, %{stop_reason: "max_tokens"} = resp}, state, _context)
       when state.overflow_retries < 2 do
    content = Map.get(resp, :content, "")
    current_max = max_response_tokens()
    bumped = min(current_max * 2, 16_384)

    Logger.info(
      "[loop] Response truncated (stop_reason=max_tokens), bumping max_tokens #{current_max} → #{bumped}"
    )

    # Inject the partial response so the model can continue from where it left off
    state = %{
      state
      | messages:
          state.messages ++
            [
              %{role: "assistant", content: content},
              %{
                role: "system",
                content:
                  "[Your previous response was truncated due to length. Continue from where you left off.]"
              }
            ],
        overflow_retries: state.overflow_retries + 1,
        iteration: state.iteration + 1
    }

    # Store bumped max_tokens for this session
    Process.put(:osa_bumped_max_tokens, bumped)
    run(state)
  end

  # No tool calls — final response or behavioural nudge
  defp handle_result({:ok, %{content: content, tool_calls: []}}, state, _context) do
    content = if is_nil(content) or String.trim(content) == "", do: "...", else: content

    content =
      if Scratchpad.inject?(state.provider) do
        Scratchpad.process_response(content, state.session_id)
      else
        content
      end

    content = if String.trim(content) == "", do: "...", else: content

    cond do
      state.auto_continues < 2 and Guardrails.wants_to_continue?(content) ->
        Logger.info(
          "[loop] Auto-continue: model described intent without tool calls (nudge #{state.auto_continues + 1}/2)"
        )

        nudge = %{
          role: "system",
          content:
            "[System: You described what you would do but did not call any tools. " <>
              "EXECUTE by calling the appropriate tools NOW. " <>
              "Give a brief 1-line status of what you're doing, then call the tools. " <>
              "Do NOT narrate step-by-step — just act. Example: " <>
              "\"Checking project structure.\" then call dir_list + file_read.]"
        }

        state = %{
          state
          | messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
            auto_continues: state.auto_continues + 1,
            iteration: state.iteration + 1
        }

        run(state)

      state.auto_continues < 3 and Guardrails.code_in_text?(content) ->
        Logger.info(
          "[loop] Coding nudge: model wrote code in markdown instead of calling file_write/file_edit (nudge #{state.auto_continues + 1}/3)"
        )

        nudge = %{
          role: "system",
          content:
            "[CRITICAL: You wrote code in markdown instead of using a tool. " <>
              "You MUST call file_write with the code as content to create the file. " <>
              "Do NOT output code in your response text — call the file_write tool NOW.]"
        }

        state = %{
          state
          | messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
            auto_continues: state.auto_continues + 1,
            iteration: state.iteration + 1
        }

        run(state)

      Guardrails.needs_verification_gate?(state) ->
        Logger.info(
          "[loop] Verification gate: iteration #{state.iteration}, task context present, zero successful tools — injecting verification"
        )

        verification = %{
          role: "system",
          content:
            "[System: VERIFICATION REQUIRED — You completed #{state.iteration} iterations with a task/goal " <>
              "but executed zero tools successfully. Before returning a final response, verify your answer: " <>
              "use at least one tool (e.g. file_read, dir_list, shell_execute) to confirm your response is accurate. " <>
              "Do NOT return a final answer without tool-backed evidence.]"
        }

        state = %{
          state
          | messages: state.messages ++ [%{role: "assistant", content: content}, verification],
            iteration: state.iteration + 1,
            auto_continues: 2
        }

        run(state)

      true ->
        # Run stop hooks — hooks can override the response or force continuation
        case run_stop_hooks(content, state) do
          {:continue, inject_msg, state} ->
            # Hook wants the agent to continue with an injected message
            state = %{
              state
              | messages: state.messages ++ [%{role: "assistant", content: content}, inject_msg],
                iteration: state.iteration + 1
            }

            run(state)

          {:override, new_content, state} ->
            # Hook overrides the final response
            {new_content, state}

          {:ok, state} ->
            # No hook intervention — return normally
            {content, state}
        end
    end
  end

  # Tool calls — execute in parallel and loop
  defp handle_result({:ok, %{content: content, tool_calls: tool_calls} = resp}, state, _context)
       when is_list(tool_calls) do
    state = %{state | iteration: state.iteration + 1}

    content =
      if Scratchpad.inject?(state.provider) do
        Scratchpad.process_response(content, state.session_id)
      else
        content
      end

    assistant_msg = %{role: "assistant", content: content, tool_calls: tool_calls}

    assistant_msg =
      case Map.get(resp, :thinking_blocks) do
        blocks when is_list(blocks) and blocks != [] ->
          Map.put(assistant_msg, :thinking_blocks, blocks)

        _ ->
          assistant_msg
      end

    state = %{state | messages: state.messages ++ [assistant_msg]}

    # Check if any tools were already started via streaming execution
    streaming_ctx = Process.get(:osa_streaming_tool_ctx)

    streaming_started_ids =
      if streaming_ctx, do: MapSet.new(streaming_ctx.order), else: MapSet.new()

    # Split: tools already started streaming vs tools that need fresh execution
    {already_streaming, need_execution} =
      Enum.split_with(tool_calls, fn tc -> tc.id in streaming_started_ids end)

    # Phase 2: per-input parallel/serial split via ToolOrchestrator. The
    # orchestrator routes through LegacyAdapter so structured tools are
    # checked per-input via `concurrency_safe?/2` while flat tools fall
    # back to the module-level `concurrent?/0`.
    fresh_results =
      ToolOrchestrator.dispatch(need_execution, state,
        max_concurrency: 10,
        timeout_ms: 60_000
      )

    # Collect streaming tool results (these may already be done)
    streaming_results =
      if streaming_ctx && StreamingToolExecutor.has_in_flight?(streaming_ctx) do
        collected = StreamingToolExecutor.collect_results(streaming_ctx)
        Enum.zip(already_streaming, collected) |> Enum.map(fn {tc, result} -> {tc, result} end)
      else
        []
      end

    # Merge results in original tool_call order
    all_results_map =
      Map.new(streaming_results ++ fresh_results, fn {tc, result} -> {tc.id, {tc, result}} end)

    results =
      Enum.map(tool_calls, fn tc ->
        Map.get(
          all_results_map,
          tc.id,
          {tc,
           {%{role: "tool", tool_call_id: tc.id, content: "Error: Tool not executed"},
            "Error: Tool not executed"}}
        )
      end)

    # Clean up streaming context
    Process.delete(:osa_streaming_tool_ctx)

    tool_messages = Enum.map(results, fn {_tc, {tool_msg, _result_str}} -> tool_msg end)
    state = %{state | messages: state.messages ++ tool_messages}

    # Short-circuit: if ALL tool calls were computer_use and ALL succeeded,
    # return directly to avoid burning another LLM round-trip.
    all_computer_use = Enum.all?(tool_calls, fn tc -> tc.name == "computer_use" end)

    all_succeeded =
      Enum.all?(results, fn {_tc, {_msg, result_str}} ->
        not String.starts_with?(result_str, "Error:")
      end)

    if all_computer_use and all_succeeded do
      summary =
        results
        |> Enum.map(fn {_tc, {_msg, result_str}} -> result_str end)
        |> Enum.join("\n")

      {summary, state}
    else
      Checkpoint.checkpoint_state(state)

      state = ToolExecutor.inject_read_nudges(state, tool_calls)

      # Invalidate system message cache if memory_save ran successfully
      if Enum.any?(tool_calls, fn tc -> tc.name == "memory_save" end) and
           Enum.any?(results, fn {tc, {_msg, result_str}} ->
             tc.name == "memory_save" and not String.starts_with?(result_str, "Error:")
           end) do
        Process.put(:osa_memory_version, Process.get(:osa_memory_version, 0) + 1)
      end

      state = inject_post_tool_nudges(state, tool_calls)

      case DoomLoop.check(results, tool_calls, state) do
        {:halt, doom_message, state} -> {doom_message, state}
        {:ok, state} -> run(state)
      end
    end
  end

  # LLM error — compact and retry or surface error
  defp handle_result({:error, reason}, state, _context) do
    alias OptimalSystemAgent.Agent.Loop.ContextCollapse

    reason_str = if is_binary(reason), do: reason, else: inspect(reason)

    if context_overflow?(reason_str) and state.overflow_retries < 3 do
      retry_num = state.overflow_retries + 1

      Logger.warning(
        "Context overflow — attempting recovery (retry #{retry_num}/3, iteration #{state.iteration})"
      )

      # Try context collapse first (cheap — just withhold large tool results)
      collapsed_messages =
        case ContextCollapse.collapse(state.messages, retry_num) do
          {:ok, collapsed} ->
            collapsed

          {:error, _} ->
            # Collapse failed — fall back to full compaction
            Logger.info("[loop] Context collapse insufficient, running full compaction")
            OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
        end

      state = %{state | messages: collapsed_messages, overflow_retries: retry_num}
      run(state)
    else
      if context_overflow?(reason_str) do
        Logger.error("Context overflow after 3 recovery attempts (iteration #{state.iteration})")
        {"I've exceeded the context window. Try breaking your request into smaller parts.", state}
      else
        Logger.error("LLM call failed: #{reason_str}")
        {"I encountered an error processing your request. Please try again.", state}
      end
    end
  end

  # Run stop hooks — allows hooks to override response or force continuation
  defp run_stop_hooks(content, state) do
    payload = %{
      content: content,
      session_id: state.session_id,
      iteration: state.iteration,
      turn_count: state.turn_count
    }

    try do
      case OptimalSystemAgent.Agent.Hooks.run(:stop, payload) do
        {:ok, %{continue: true, message: msg}} ->
          inject = %{role: "system", content: msg}
          {:continue, inject, state}

        {:ok, %{override: new_content}} ->
          {:override, new_content, state}

        _ ->
          {:ok, state}
      end
    rescue
      _ -> {:ok, state}
    catch
      :exit, _ -> {:ok, state}
    end
  end

  # Inject pre-fetched memory results into context (from async prefetch)
  defp inject_prefetched_memory(context, memories) when is_list(memories) do
    memory_content =
      Enum.map(memories, fn m ->
        key = Map.get(m, :key, Map.get(m, :content, ""))
        "- #{key}"
      end)
      |> Enum.join("\n")

    if memory_content != "" do
      memory_msg = %{
        role: "system",
        content: "[Relevant memories]\n#{memory_content}"
      }

      %{context | messages: context.messages ++ [memory_msg]}
    else
      context
    end
  end

  # Drain any {:streaming_tool_block, tool_call} messages from the process mailbox
  # that arrived during the LLM streaming call. Each one triggers immediate execution.
  defp drain_streaming_tool_blocks(ctx, state) do
    receive do
      {:streaming_tool_block, tool_call} ->
        updated = StreamingToolExecutor.tool_block_complete(ctx, tool_call, state)
        drain_streaming_tool_blocks(updated, state)
    after
      # No more messages — return
      0 -> ctx
    end
  end

  defp inject_post_tool_nudges(state, tool_calls) do
    has_edit_tools = Enum.any?(tool_calls, fn tc -> tc.name in ~w(file_edit shell_execute) end)

    state =
      if state.iteration == 1 and
           state.auto_continues < 2 and
           has_edit_tools and
           Guardrails.write_without_read?(tool_calls) do
        Logger.info("[loop] Explore-first nudge: model edited files before reading (iteration 1)")

        nudge = %{
          role: "system",
          content:
            "[System: You modified existing files without reading them first. " <>
              "Always explore before you act: call dir_list and file_read to understand " <>
              "the current state of relevant files before making changes. " <>
              "On your next step, read what you changed to verify it's correct.]"
        }

        %{state | messages: state.messages ++ [nudge], auto_continues: state.auto_continues + 1}
      else
        state
      end

    if length(tool_calls) >= 5 and state.iteration == 1 do
      nudge_msg = %{
        role: "system",
        content:
          "[System: You've used 5+ tools this turn. " <>
            "If this is a reusable pattern, consider create_skill.]"
      }

      %{state | messages: state.messages ++ [nudge_msg]}
    else
      state
    end
  end

  # Frozen system prompt cache — avoids rebuilding the system message on every
  # iteration within a single process_message call. Cache key includes plan_mode,
  # session_id, memory version, and channel so it auto-invalidates on any change.
  defp cached_context(state) do
    cache_key =
      {state.plan_mode, state.session_id, Process.get(:osa_memory_version, 0), state.channel}

    case Process.get(:osa_system_msg_cache) do
      {^cache_key, cached_system_msg} ->
        full = Context.build(state)

        case full do
          %{messages: [_system | rest]} -> %{full | messages: [cached_system_msg | rest]}
          %{messages: _} -> full
          _ -> Context.build(state)
        end

      _ ->
        full = Context.build(state)

        case full do
          %{messages: [system_msg | _]} when system_msg != nil ->
            Process.put(:osa_system_msg_cache, {cache_key, system_msg})
            full

          _ ->
            full
        end
    end
  end

  defp maybe_inject_memory(context, %{iteration: 0, session_id: sid}) do
    try do
      injected = OptimalSystemAgent.Memory.Synthesis.inject(context.messages, sid)
      %{context | messages: injected}
    rescue
      e ->
        Logger.debug("[loop] Memory injection skipped: #{inspect(e)}")
        context
    end
  end

  defp maybe_inject_memory(context, _state), do: context

  defp inject_pending_agent_messages(context, state) do
    messages =
      try do
        OptimalSystemAgent.Tools.Builtins.SendMessage.drain_pending_messages(state.session_id)
      rescue
        _ -> []
      end

    if messages == [] do
      context
    else
      injections =
        Enum.map(messages, fn msg ->
          %{
            role: "system",
            content: "[Message from agent #{msg.from}]: #{msg.content}"
          }
        end)

      %{context | messages: context.messages ++ injections}
    end
  end

  defp inject_iteration_budget(context, state) do
    max_iter = max_iterations()
    remaining = max_iter - state.iteration

    if state.iteration > 0 and remaining <= max_iter do
      budget_msg = %{
        role: "system",
        content:
          "[Iteration #{state.iteration + 1}/#{max_iter} — #{remaining} remaining. Be efficient. Wrap up if the task is done.]"
      }

      %{context | messages: context.messages ++ [budget_msg]}
    else
      context
    end
  end

  defp context_overflow?(reason) do
    String.contains?(reason, "context_length") or
      String.contains?(reason, "max_tokens") or
      String.contains?(reason, "maximum context length") or
      String.contains?(reason, "token limit")
  end
end
