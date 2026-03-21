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
  alias OptimalSystemAgent.Events.Bus

  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Agent.Loop.DoomLoop
  alias OptimalSystemAgent.Agent.Loop.Telemetry

  @cancel_table :osa_cancel_flags

  defp max_iterations, do: Application.get_env(:optimal_system_agent, :max_iterations, 30)
  defp max_response_tokens, do: Application.get_env(:optimal_system_agent, :max_response_tokens, 8_192)

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
        {"I've used all #{max_iter} iterations on this task.\n\n**Tools used:** #{tools_used}\n\nIf the task isn't complete, try breaking it into smaller steps or giving more specific instructions.", state}

      true ->
        do_iteration(state)
    end
  end

  # --- Private ---

  defp do_iteration(state) do
    Logger.debug("[loop] do_iteration entered for #{state.session_id}, iteration=#{state.iteration}")

    context = cached_context(state)
    Logger.debug("[loop] context built, #{length(context.messages)} messages")

    context = maybe_inject_memory(context, state)
    context = inject_iteration_budget(context, state)

    max_iter = max_iterations()
    Logger.debug("[loop] About to call LLM for #{state.session_id}, iteration #{state.iteration + 1}/#{max_iter}")
    Bus.emit(:llm_request, %{session_id: state.session_id, iteration: state.iteration, agent: state.session_id})

    start_time = System.monotonic_time(:millisecond)
    thinking_opts = LLMClient.thinking_config(state)
    tools_for_call = ToolFilter.filter(state.tools, state)

    llm_opts = [tools: tools_for_call, temperature: LLMClient.temperature(), max_tokens: max_response_tokens()]
    llm_opts = if thinking_opts, do: Keyword.put(llm_opts, :thinking, thinking_opts), else: llm_opts

    result = LLMClient.llm_chat_stream(state, context.messages, llm_opts)
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
        Logger.info("[loop] Auto-continue: model described intent without tool calls (nudge #{state.auto_continues + 1}/2)")

        nudge = %{
          role: "system",
          content:
            "[System: You described what you would do but did not call any tools. " <>
              "EXECUTE by calling the appropriate tools NOW. " <>
              "Give a brief 1-line status of what you're doing, then call the tools. " <>
              "Do NOT narrate step-by-step — just act. Example: " <>
              "\"Checking project structure.\" then call dir_list + file_read.]"
        }

        state = %{state |
          messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
          auto_continues: state.auto_continues + 1,
          iteration: state.iteration + 1
        }

        run(state)

      state.auto_continues < 3 and Guardrails.code_in_text?(content) ->
        Logger.info("[loop] Coding nudge: model wrote code in markdown instead of calling file_write/file_edit (nudge #{state.auto_continues + 1}/3)")

        nudge = %{
          role: "system",
          content:
            "[CRITICAL: You wrote code in markdown instead of using a tool. " <>
              "You MUST call file_write with the code as content to create the file. " <>
              "Do NOT output code in your response text — call the file_write tool NOW.]"
        }

        state = %{state |
          messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
          auto_continues: state.auto_continues + 1,
          iteration: state.iteration + 1
        }

        run(state)

      Guardrails.needs_verification_gate?(state) ->
        Logger.info("[loop] Verification gate: iteration #{state.iteration}, task context present, zero successful tools — injecting verification")

        verification = %{
          role: "system",
          content:
            "[System: VERIFICATION REQUIRED — You completed #{state.iteration} iterations with a task/goal " <>
              "but executed zero tools successfully. Before returning a final response, verify your answer: " <>
              "use at least one tool (e.g. file_read, dir_list, shell_execute) to confirm your response is accurate. " <>
              "Do NOT return a final answer without tool-backed evidence.]"
        }

        state = %{state |
          messages: state.messages ++ [%{role: "assistant", content: content}, verification],
          iteration: state.iteration + 1,
          auto_continues: 2
        }

        run(state)

      true ->
        {content, state}
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
        blocks when is_list(blocks) and blocks != [] -> Map.put(assistant_msg, :thinking_blocks, blocks)
        _ -> assistant_msg
      end

    state = %{state | messages: state.messages ++ [assistant_msg]}

    results =
      OptimalSystemAgent.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        tool_calls,
        fn tool_call -> ToolExecutor.execute_tool_call(tool_call, state) end,
        max_concurrency: 10,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(tool_calls)
      |> Enum.map(fn
        {{:ok, result}, tool_call} ->
          {tool_call, result}

        {_, tool_call} ->
          timeout_msg = %{role: "tool", tool_call_id: tool_call.id, name: tool_call.name, content: "Error: Tool execution timed out"}
          {tool_call, {timeout_msg, "Error: Tool execution timed out"}}
      end)

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
    reason_str = if is_binary(reason), do: reason, else: inspect(reason)

    if context_overflow?(reason_str) and state.overflow_retries < 3 do
      Logger.warning("Context overflow — compacting and retrying (overflow_retry #{state.overflow_retries + 1}/3, iteration #{state.iteration})")
      compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
      state = %{state | messages: compacted, overflow_retries: state.overflow_retries + 1}
      run(state)
    else
      if context_overflow?(reason_str) do
        Logger.error("Context overflow after 3 compaction attempts (iteration #{state.iteration})")
        {"I've exceeded the context window. Try breaking your request into smaller parts.", state}
      else
        Logger.error("LLM call failed: #{reason_str}")
        {"I encountered an error processing your request. Please try again.", state}
      end
    end
  end

  # Post-tool nudges: explore-first and skill-creation hints.
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
    cache_key = {state.plan_mode, state.session_id, Process.get(:osa_memory_version, 0), state.channel}

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

  defp inject_iteration_budget(context, state) do
    max_iter = max_iterations()
    remaining = max_iter - state.iteration

    if state.iteration > 0 and remaining <= max_iter do
      budget_msg = %{
        role: "system",
        content: "[Iteration #{state.iteration + 1}/#{max_iter} — #{remaining} remaining. Be efficient. Wrap up if the task is done.]"
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
