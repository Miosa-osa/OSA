defmodule OptimalSystemAgent.Agent.Loop do
  @moduledoc """
  Bounded ReAct agent loop — the core reasoning engine.

  Message goes straight to the LLM with the system prompt. The LLM
  self-classifies signals via Signal Theory instructions in SYSTEM.md.
  No middleware between user and model.

  Flow:
    1. Receive message from channel/bus
    2. Build context (identity + memory + runtime)
    3. Call LLM with available tools
    4. If tool_calls: execute each, append results, re-prompt
    5. When no tool_calls: return final response
    6. Write to memory, notify channel
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Channels.NoiseFilter

  defp max_iterations, do: Application.get_env(:optimal_system_agent, :max_iterations, 30)
  # Tool results larger than this are truncated before being added to the
  # conversation to prevent context overflow. Default: 10 KB.
  defp max_tool_output_bytes, do: Application.get_env(:optimal_system_agent, :max_tool_output_bytes, 10_240)

  # ETS table for cancel flags — checked each loop iteration.
  # Created in application.ex, written by cancel/1, read by run_loop.
  @cancel_table :osa_cancel_flags

  defstruct [
    :session_id,
    :user_id,
    :channel,
    :provider,
    :model,
    messages: [],
    iteration: 0,
    overflow_retries: 0,
    recent_failure_signatures: [],
    auto_continues: 0,
    status: :idle,
    tools: [],
    plan_mode: false,
    plan_mode_enabled: false,
    turn_count: 0,
    last_meta: %{iteration_count: 0, tools_used: []}
  ]

  # --- Client API ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    user_id = Keyword.get(opts, :user_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id, user_id}})
  end

  def process_message(session_id, message, opts \\ []) do
    GenServer.call(via(session_id), {:process, message, opts}, :infinity)
  end

  @doc "Get metadata from the last process_message call (iteration_count, tools_used)."
  def get_metadata(session_id) do
    GenServer.call(via(session_id), :get_metadata)
  rescue
    _ -> %{iteration_count: 0, tools_used: []}
  end

  @doc """
  Cancel a running agent loop for the given session.

  Sets a flag in an ETS table that the run_loop checks at each iteration.
  This works even though handle_call blocks the GenServer mailbox,
  because ETS reads are concurrent.
  """
  def cancel(session_id) do
    :ets.insert(@cancel_table, {session_id, true})
    Logger.info("[loop] Cancel requested for session #{session_id}")
    :ok
  rescue
    ArgumentError ->
      Logger.warning("[loop] Cancel table not found — agent may not be running")
      {:error, :not_running}
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    extra_tools = Keyword.get(opts, :extra_tools, [])

    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      user_id: Keyword.get(opts, :user_id),
      channel: Keyword.get(opts, :channel, :cli),
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      messages: Keyword.get(opts, :messages, []),
      tools: Tools.list_tools_direct() ++ extra_tools,
      plan_mode_enabled: Application.get_env(:optimal_system_agent, :plan_mode_enabled, false)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:process, message}, from, state) do
    handle_call({:process, message, []}, from, state)
  end

  @impl true
  def handle_call({:process, message, opts}, _from, state) do
    skip_plan = Keyword.get(opts, :skip_plan, false)

    # Clear any stale cancel flag for this session
    try do
      :ets.delete(@cancel_table, state.session_id)
    rescue
      ArgumentError -> :ok
    end

    # Apply per-call provider/model overrides (SDK passthrough)
    state = apply_overrides(state, opts)

    # Increment turn counter for memory/skill nudges (Phase 6)
    state = %{state | turn_count: state.turn_count + 1}

    # 0. Clear per-message caches (git info and workspace overview run once per message, not per iteration)
    Process.delete(:osa_git_info_cache)
    Process.delete(:osa_workspace_overview_cache)

    # Clear system message cache at start of each process call (Phase 4)
    Process.delete(:osa_system_msg_cache)
    Process.put(:osa_memory_version, 0)

    # 0.5. Application-layer prompt injection guard — block before LLM ever sees it.
    # This catches weak local models (Ollama) that ignore system prompt instructions.
    if prompt_injection?(message) do
      refusal = "I can't help with that."
      Memory.append(state.session_id, %{role: "user", content: message, channel: state.channel})
      Memory.append(state.session_id, %{role: "assistant", content: refusal, channel: state.channel})
      state = %{state | status: :idle}
      {:reply, {:ok, refusal}, state}
    else

    # 1. Persist user message to JSONL session storage
    Memory.append(state.session_id, %{role: "user", content: message, channel: state.channel})

    # 1.5. Noise filter — intercept low-signal messages before reaching the LLM.
    # signal_weight comes from an upstream classifier (e.g. HTTP handler that called
    # /api/v1/classify first). Defaults to nil (no weight check, Tier 1 regex only).
    signal_weight = Keyword.get(opts, :signal_weight, nil)

    noise_result = NoiseFilter.check(message, signal_weight)

    if noise_result != :pass do
      ack =
        case noise_result do
          {:filtered, ack} -> ack
          {:clarify, prompt} -> prompt
        end

      Memory.append(state.session_id, %{role: "assistant", content: ack, channel: state.channel})
      state = %{state | status: :idle}
      {:reply, {:ok, ack}, state}
    else

    # 2. Compact message history if needed, then process through agent loop
    compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
    state = %{state | messages: compacted}

    # Auto-extract insights from recent conversation history every 10 turns.
    # This runs silently — no user-visible output.
    if rem(state.turn_count, 10) == 0 and state.turn_count > 0 do
      recent = Enum.take(state.messages, -20)
      Task.start(fn -> Memory.extract_insights(recent) end)
    end

    # Memory nudge every 10 turns (Phase 6)
    # After complex tasks (>5 turns), also check for unsaved patterns to suggest saving.
    message_with_nudge =
      cond do
        rem(state.turn_count, 10) == 0 and state.turn_count > 0 ->
          message <>
            "\n\n[System: You've had #{state.turn_count} exchanges. " <>
            "Consider saving important context with memory_save if you haven't recently.]"

        state.turn_count > 5 ->
          recent = Enum.take(state.messages, -10)
          case Memory.maybe_pattern_nudge(state.turn_count, recent) do
            {:nudge, nudge_text} ->
              message <> "\n\n[System: #{nudge_text}]"

            :no_nudge ->
              message
          end

        true ->
          message
      end

    # Inject an exploration directive before complex coding tasks so local models
    # read relevant files BEFORE writing — the "explore first" pattern.
    messages_to_append =
      if complex_coding_task?(message_with_nudge) do
        [
          %{
            role: "system",
            content:
              "[System: This task involves code changes. MANDATORY explore-first protocol: " <>
                "Call dir_list and file_read to understand the relevant structure BEFORE " <>
                "calling file_write, file_edit, or shell_execute. " <>
                "Never modify a file you haven't read first.]"
          },
          %{role: "user", content: message_with_nudge}
        ]
      else
        [%{role: "user", content: message_with_nudge}]
      end

    state = %{
      state
      | messages: state.messages ++ messages_to_append,
        iteration: 0,
        overflow_retries: 0,
        auto_continues: 0,
        status: :thinking
    }

    # 2.5. Genre routing — adjust behavior based on signal type when provided by caller.
    # Callers that pre-classify messages pass :signal_genre in opts.
    # Defaults to :direct (current behavior: execute tools immediately).
    signal_genre = Keyword.get(opts, :signal_genre, :direct)

    genre_route = route_by_genre(signal_genre, message, state)

    case genre_route do
      {:respond, genre_response} ->
        Memory.append(state.session_id, %{role: "assistant", content: genre_response, channel: state.channel})
        state = %{state | status: :idle}
        Bus.emit(:agent_response, %{session_id: state.session_id, response: genre_response})
        {:reply, {:ok, genre_response}, state}

      :execute_tools ->
    # 3. Check if plan mode should trigger
    if not skip_plan and should_plan?(state) do
      # Plan mode: single LLM call with plan overlay, no tools
      state = %{state | plan_mode: true}
      context = Context.build(state)

      Bus.emit(:llm_request, %{session_id: state.session_id, iteration: 0})
      start_time = System.monotonic_time(:millisecond)

      result = llm_chat(state, context.messages, tools: [], temperature: 0.3)

      duration_ms = System.monotonic_time(:millisecond) - start_time

      usage =
        case result do
          {:ok, resp} -> Map.get(resp, :usage, %{})
          _ -> %{}
        end

      Bus.emit(:llm_response, %{
        session_id: state.session_id,
        duration_ms: duration_ms,
        usage: usage
      })

      case result do
        {:ok, %{content: plan_text}} ->
          Memory.append(state.session_id, %{role: "assistant", content: plan_text, channel: state.channel})
          state = %{state | plan_mode: false, status: :idle}
          emit_context_pressure(state)

          Bus.emit(:agent_response, %{
            session_id: state.session_id,
            response: plan_text,
            response_type: "plan"
          })

          {:reply, {:plan, plan_text}, state}

        {:error, reason} ->
          # Fall through to normal execution on plan failure
          Logger.warning(
            "Plan mode LLM call failed (#{inspect(reason)}), falling back to normal execution"
          )

          state = %{state | plan_mode: false}
          {response, state} = run_loop(state)

          state = %{
            state
            | messages: state.messages ++ [%{role: "assistant", content: response}],
              status: :idle
          }

          Memory.append(state.session_id, %{role: "assistant", content: response, channel: state.channel})

          emit_context_pressure(state)

          meta = %{iteration_count: state.iteration, tools_used: extract_tools_used(state.messages)}
          state = %{state | last_meta: meta}

          Bus.emit(:agent_response, %{
            session_id: state.session_id,
            response: response
          })

          {:reply, {:ok, response}, state}
      end
    else
      # Normal execution path — message goes straight to LLM
      {response, state} = run_loop(state)

      meta = %{iteration_count: state.iteration, tools_used: extract_tools_used(state.messages)}

      state = %{
        state
        | messages: state.messages ++ [%{role: "assistant", content: response}],
          status: :idle,
          last_meta: meta
      }

      # 4. Persist assistant response to JSONL session storage
      Memory.append(state.session_id, %{role: "assistant", content: response, channel: state.channel})

      emit_context_pressure(state)

      Bus.emit(:agent_response, %{
        session_id: state.session_id,
        response: response
      })

      {:reply, {:ok, response}, state}
    end
    end  # closes :execute_tools arm of route_by_genre case
    end  # closes noise_filter :pass else branch
    end  # closes prompt_injection? else branch
  end

  @impl true
  def handle_call(:get_metadata, _from, state) do
    {:reply, state.last_meta, state}
  end

  @impl true
  def handle_call(:toggle_plan_mode, _from, state) do
    new_val = not state.plan_mode_enabled
    {:reply, {:ok, new_val}, %{state | plan_mode_enabled: new_val}}
  end

  # --- Agent Loop ---

  defp run_loop(%{iteration: iter, session_id: sid} = state) do
    # Check cancel flag (ETS read — concurrent-safe even during handle_call)
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
        Logger.warning("Agent loop hit max iterations (#{max_iter})")
        {"I've reached my reasoning limit for this request. Here's what I have so far.", state}

      true ->
        do_run_loop(state)
    end
  end

  defp do_run_loop(state) do
    # Build context (system prompt + conversation history), using cached system message (Phase 4)
    context = cached_context(state)

    # Emit timing event before LLM call
    Bus.emit(:llm_request, %{session_id: state.session_id, iteration: state.iteration})
    start_time = System.monotonic_time(:millisecond)

    # Call LLM with streaming — emits per-token SSE events for live TUI display.
    # Falls back to sync chat if streaming is unavailable.
    thinking_opts = thinking_config(state)
    llm_opts = [tools: state.tools, temperature: temperature()]
    llm_opts = if thinking_opts, do: Keyword.put(llm_opts, :thinking, thinking_opts), else: llm_opts
    result = llm_chat_stream(state, context.messages, llm_opts)

    # Emit timing + usage event after LLM call
    duration_ms = System.monotonic_time(:millisecond) - start_time

    usage =
      case result do
        {:ok, resp} -> Map.get(resp, :usage, %{})
        _ -> %{}
      end

    Bus.emit(:llm_response, %{
      session_id: state.session_id,
      duration_ms: duration_ms,
      usage: usage
    })

    case result do
      {:ok, %{content: content, tool_calls: []}} ->
        # No tool calls — final response. Guard empty content (Bug 27: Unicode messages
        # from small local models sometimes return whitespace-only responses).
        content = if is_nil(content) or String.trim(content) == "", do: "...", else: content

        cond do
          state.auto_continues < 2 and wants_to_continue?(content) ->
            Logger.info("[loop] Auto-continue: model described intent without tool calls (nudge #{state.auto_continues + 1}/2)")
            nudge = %{
              role: "system",
              content: "[System: You described what you would do but did not call any tools. " <>
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
            run_loop(state)

          state.auto_continues < 2 and code_in_text?(content) ->
            Logger.info("[loop] Coding nudge: model wrote code in markdown instead of calling file_write/file_edit (nudge #{state.auto_continues + 1}/2)")
            nudge = %{
              role: "system",
              content: "[System: You wrote code in a markdown code block instead of saving it to a file. " <>
                "Call file_write to create the file or file_edit to modify an existing one. " <>
                "Do NOT show code in your response — use the tool to write it directly to disk.]"
            }
            state = %{state |
              messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
              auto_continues: state.auto_continues + 1,
              iteration: state.iteration + 1
            }
            run_loop(state)

          true ->
            {content, state}
        end

      {:ok, %{content: content, tool_calls: tool_calls} = resp} when is_list(tool_calls) ->
        # Execute tool calls
        state = %{state | iteration: state.iteration + 1}

        # Append assistant message with tool calls (+ thinking blocks for preservation)
        assistant_msg = %{role: "assistant", content: content, tool_calls: tool_calls}
        assistant_msg =
          case Map.get(resp, :thinking_blocks) do
            blocks when is_list(blocks) and blocks != [] -> Map.put(assistant_msg, :thinking_blocks, blocks)
            _ -> assistant_msg
          end

        state = %{state | messages: state.messages ++ [assistant_msg]}

        # Execute all tool calls in parallel — independent by contract
        # (if the LLM needed sequential execution, it would return them
        # across separate iterations)
        results =
          tool_calls
          |> Task.async_stream(
            fn tool_call -> execute_tool_call(tool_call, state) end,
            max_concurrency: 10,
            timeout: 60_000,
            on_timeout: :kill_task
          )
          |> Enum.zip(tool_calls)
          |> Enum.map(fn
            {{:ok, result}, tool_call} ->
              {tool_call, result}

            {_, tool_call} ->
              timeout_msg = %{role: "tool", tool_call_id: tool_call.id, content: "Error: Tool execution timed out"}
              {tool_call, {timeout_msg, "Error: Tool execution timed out"}}
          end)

        # Append all tool messages in original order
        tool_messages = Enum.map(results, fn {_tc, {tool_msg, _result_str}} -> tool_msg end)
        state = %{state | messages: state.messages ++ tool_messages}

        # If memory_save ran successfully in this batch, invalidate system message cache (Phase 4)
        if Enum.any?(tool_calls, fn tc -> tc.name == "memory_save" end) and
             Enum.any?(results, fn {tc, {_msg, result_str}} ->
               tc.name == "memory_save" and not String.starts_with?(result_str, "Error:")
             end) do
          Process.put(:osa_memory_version, Process.get(:osa_memory_version, 0) + 1)
        end

        # Explore-first nudge — if the model writes/edits files without reading first at iteration 1
        state =
          if state.iteration == 1 and
               state.auto_continues < 2 and
               write_without_read?(tool_calls) do
            Logger.info("[loop] Explore-first nudge: model issued write tools before reading (iteration 1)")

            nudge = %{
              role: "system",
              content:
                "[System: You modified files without reading them first. " <>
                  "Always explore before you act: call dir_list and file_read to understand " <>
                  "the current state of relevant files before making changes. " <>
                  "On your next step, read what you changed to verify it's correct.]"
            }

            %{state | messages: state.messages ++ [nudge], auto_continues: state.auto_continues + 1}
          else
            state
          end

        # Skill creation nudge — 5+ tool calls in single turn suggests a reusable pattern (Phase 6)
        state =
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

        # Doom loop detection — if the same tools fail 3x consecutively, halt
        tool_signature = tool_calls |> Enum.map(& &1.name) |> Enum.sort()

        all_failed =
          Enum.all?(results, fn {_tc, {_msg, result_str}} ->
            String.starts_with?(result_str, "Error:") or
              String.starts_with?(result_str, "Blocked:")
          end)

        recent_failure_signatures =
          if all_failed do
            # Prepend and keep at most the last 6 entries
            [tool_signature | state.recent_failure_signatures] |> Enum.take(6)
          else
            []
          end

        state = %{state | recent_failure_signatures: recent_failure_signatures}

        doom_loop? =
          length(recent_failure_signatures) >= 3 and
            (
              # Condition 1: same signature appears 3+ times in the window
              Enum.any?(
                Enum.uniq(recent_failure_signatures),
                fn sig -> Enum.count(recent_failure_signatures, &(&1 == sig)) >= 3 end
              ) or
                # Condition 2: all 6 slots filled — sustained failure regardless of pattern
                length(recent_failure_signatures) >= 6
            )

        if doom_loop? do
          failure_count = length(recent_failure_signatures)

          Bus.emit(:system_event, %{
            event: :doom_loop_detected,
            session_id: state.session_id,
            tool_signature: tool_signature,
            consecutive_failures: failure_count
          })

          {"I'm stuck — the same tools have failed 3 times in a row. " <>
             "Let me reassess the approach rather than keep trying the same thing.", state}
        else
          # Re-prompt
          run_loop(state)
        end

      {:error, reason} ->
        reason_str = if is_binary(reason), do: reason, else: inspect(reason)

        if context_overflow?(reason_str) and state.overflow_retries < 3 do
          Logger.warning("Context overflow — compacting and retrying (overflow_retry #{state.overflow_retries + 1}/3, iteration #{state.iteration})")
          compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
          state = %{state | messages: compacted, overflow_retries: state.overflow_retries + 1}
          run_loop(state)
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
  end

  # Frozen system prompt cache (Phase 4) — avoids rebuilding the system message
  # on every iteration within a single process_message call. The cache key includes
  # plan_mode, session_id, memory version, and channel so it auto-invalidates when
  # any of those change (e.g. memory_save bumps the version).
  defp cached_context(state) do
    cache_key =
      {state.plan_mode, state.session_id, Process.get(:osa_memory_version, 0), state.channel}

    case Process.get(:osa_system_msg_cache) do
      {^cache_key, cached_system_msg} ->
        # Rebuild with cached system message but fresh conversation history
        full = Context.build(state)

        case full.messages do
          [_system | rest] -> %{full | messages: [cached_system_msg | rest]}
          _ -> full
        end

      _ ->
        full = Context.build(state)
        system_msg = List.first(full.messages)

        if system_msg do
          Process.put(:osa_system_msg_cache, {cache_key, system_msg})
        end

        full
    end
  end

  defp context_overflow?(reason) do
    String.contains?(reason, "context_length") or
      String.contains?(reason, "max_tokens") or
      String.contains?(reason, "maximum context length") or
      String.contains?(reason, "token limit")
  end

  defp tool_call_hint(%{"command" => cmd}), do: String.slice(cmd, 0, 60)
  defp tool_call_hint(%{"path" => p}), do: p
  defp tool_call_hint(%{"query" => q}), do: String.slice(q, 0, 60)

  defp tool_call_hint(args) when is_map(args) and map_size(args) > 0 do
    args |> Map.keys() |> Enum.take(2) |> Enum.join(", ")
  end

  defp tool_call_hint(_), do: ""

  # --- Parallel Tool Execution ---

  # Execute a single tool call — used by parallel Task.async_stream.
  # Returns {tool_msg, result_str} tuple.
  defp execute_tool_call(tool_call, state) do
    arg_hint = tool_call_hint(tool_call.arguments)
    Bus.emit(:tool_call, %{name: tool_call.name, phase: :start, args: arg_hint, session_id: state.session_id})
    start_time_tool = System.monotonic_time(:millisecond)

    # Run pre_tool_use hooks sync (security_check/spend_guard can block)
    pre_payload = %{
      tool_name: tool_call.name,
      arguments: tool_call.arguments,
      session_id: state.session_id
    }

    tool_result =
      case run_hooks(:pre_tool_use, pre_payload) do
        {:blocked, reason} ->
          "Blocked: #{reason}"

        {:error, :hooks_unavailable} ->
          # Hooks GenServer is down — fail closed. Never execute a tool when
          # security_check and spend_guard are unreachable.
          Logger.error("[loop] Blocking tool #{tool_call.name} — pre_tool_use hooks unavailable (session: #{state.session_id})")
          "Blocked: security pipeline unavailable"

        _ ->
          case Tools.execute(tool_call.name, tool_call.arguments) do
            {:ok, {:image, %{media_type: mt, data: b64, path: p}}} ->
              {:image, mt, b64, p}

            {:ok, content} ->
              content

            {:error, reason} ->
              "Error: #{reason}"
          end
      end

    tool_duration_ms = System.monotonic_time(:millisecond) - start_time_tool

    # Normalize result for hooks/events
    result_str =
      case tool_result do
        {:image, _mt, _b64, path} -> "[image: #{path}]"
        text when is_binary(text) -> text
        other -> inspect(other)
      end

    # Run post_tool_use hooks async (cost tracker, telemetry, learning)
    post_payload = %{
      tool_name: tool_call.name,
      result: result_str,
      duration_ms: tool_duration_ms,
      session_id: state.session_id
    }

    run_hooks_async(:post_tool_use, post_payload)

    Bus.emit(:tool_call, %{
      name: tool_call.name,
      phase: :end,
      duration_ms: tool_duration_ms,
      args: arg_hint,
      session_id: state.session_id
    })

    Bus.emit(:tool_result, %{
      name: tool_call.name,
      result: String.slice(result_str, 0, 500),
      success: !match?({:error, _}, tool_result),
      session_id: state.session_id
    })

    # Build tool message — images get structured content blocks
    tool_msg =
      case tool_result do
        {:image, media_type, b64, path} ->
          %{
            role: "tool",
            tool_call_id: tool_call.id,
            content: [
              %{type: "text", text: "Image: #{path}"},
              %{type: "image", source: %{type: "base64", media_type: media_type, data: b64}}
            ]
          }

        _ ->
          limit = max_tool_output_bytes()
          content =
            if byte_size(result_str) > limit do
              truncated = binary_part(result_str, 0, limit)
              truncated <> "\n\n[Output truncated — #{byte_size(result_str)} bytes total, showing first #{limit} bytes]"
            else
              result_str
            end

          %{role: "tool", tool_call_id: tool_call.id, content: content}
      end

    {tool_msg, result_str}
  end

  # --- Provider/Model Passthrough ---

  # Route LLM calls through Providers.chat with per-session provider/model
  defp llm_chat(%{provider: provider, model: model}, messages, opts) do
    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts
    Providers.chat(messages, opts)
  end

  # Streaming variant — emits per-token SSE events via Bus, returns {:ok, result} | {:error, reason}.
  # Uses process dictionary to capture the {:done, result} from the streaming callback,
  # since chat_stream/3 returns :ok on success (not the accumulated result).
  defp llm_chat_stream(%{session_id: session_id, provider: provider, model: model}, messages, opts) do
    # Stash result from {:done, _} callback into process dictionary
    Process.put(:llm_stream_result, nil)

    callback = fn
      {:text_delta, text} ->
        Logger.debug("[stream] text_delta #{byte_size(text)}B → session:#{session_id}")
        Bus.emit(:system_event, %{
          event: :streaming_token,
          session_id: session_id,
          text: text
        })

      {:done, result} ->
        Logger.info("[stream] done → session:#{session_id}")
        Process.put(:llm_stream_result, result)

      {:thinking_delta, text} ->
        Bus.emit(:system_event, %{
          event: :thinking_delta,
          session_id: session_id,
          text: text
        })

      # Ignore tool_use deltas — these are handled after the full result
      _other ->
        :ok
    end

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts

    case Providers.chat_stream(messages, callback, opts) do
      :ok ->
        case Process.get(:llm_stream_result) do
          nil -> {:error, "Stream completed but no result received"}
          result -> {:ok, result}
        end

      {:error, _} = err ->
        err
    end
  end

  # Apply per-call overrides from opts (SDK query passthrough)
  defp apply_overrides(state, opts) do
    state
    |> maybe_override(:provider, Keyword.get(opts, :provider))
    |> maybe_override(:model, Keyword.get(opts, :model))
  end

  defp maybe_override(state, _key, nil), do: state
  defp maybe_override(state, key, value), do: Map.put(state, key, value)

  # --- Plan Mode ---

  defp should_plan?(state) do
    # Plan mode triggers when explicitly enabled by the user.
    # The skip_plan: true opt (passed by CLI on approved plan execution)
    # bypasses this check entirely at the handle_call level.
    # The LLM decides whether the message warrants a plan via prompt instructions.
    state.plan_mode_enabled and not state.plan_mode
  end

  # --- Genre Routing ---

  # Routes message handling based on the signal genre from upstream classification.
  # Returns {:respond, text} to short-circuit with a direct response,
  # or :execute_tools to continue normal LLM + tool execution.
  #
  # Genres from Signal Theory 5-tuple Type field:
  #   :direct   — user wants something done → execute tools (default)
  #   :inform   — user is sharing info → suggest memory_save, no tools
  #   :express  — emotional content → empathetic response, no tools
  #   :decide   — user needs help deciding → ask clarifying question first
  #   :commit   — user is committing to an action → confirm plan before executing

  defp route_by_genre(:inform, _message, _state) do
    {:respond,
     "Got it — I've noted that. Would you like me to save this to memory with `memory_save` so I can reference it later?"}
  end

  defp route_by_genre(:express, message, _state) do
    # Acknowledge emotional content with empathy, skip tools
    lower = String.downcase(message)

    response =
      cond do
        Regex.match?(~r/\b(frustrated?|annoyed?|angry|upset|irritated?)\b/, lower) ->
          "I hear you — that sounds frustrating. I'm here to help. What would make things easier right now?"

        Regex.match?(~r/\b(worried|anxious|nervous|scared|overwhelmed)\b/, lower) ->
          "That sounds stressful. Let's take it one step at a time. What's the most pressing thing on your mind?"

        Regex.match?(~r/\b(happy|excited|great|awesome|amazing|love)\b/, lower) ->
          "That's great to hear! How can I help you build on that?"

        true ->
          "I appreciate you sharing that. How can I best support you right now?"
      end

    {:respond, response}
  end

  defp route_by_genre(:decide, _message, _state) do
    # Ask a clarifying question before committing to any action
    {:respond,
     "Before I proceed — could you help me understand a bit more? Specifically: what outcome matters most to you here, and are there any constraints I should know about? Once I have that I can give you a more useful recommendation."}
  end

  defp route_by_genre(:commit, message, _state) do
    # Surface the implied plan and ask for confirmation before executing
    {:respond,
     "Just to confirm before I proceed: based on what you've said, my plan would be to #{summarize_intent(message)}. Should I go ahead with that?"}
  end

  defp route_by_genre(_genre, _message, _state) do
    # :direct or any unknown genre → normal tool execution
    :execute_tools
  end

  # Extract a short intent summary from the message for the :commit confirmation prompt.
  defp summarize_intent(message) do
    words = message |> String.split(~r/\s+/, trim: true) |> Enum.take(12)
    summary = Enum.join(words, " ")
    if String.length(message) > String.length(summary), do: "#{summary}…", else: summary
  end

  # --- Helpers ---

  defp via(session_id), do: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}}

  @doc """
  Returns the owner (user_id) stored in the SessionRegistry for the given session,
  or `nil` if the session does not exist.
  """
  @spec get_owner(String.t()) :: String.t() | nil
  def get_owner(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, owner}] -> owner
      _ -> nil
    end
  end

  defp temperature, do: Application.get_env(:optimal_system_agent, :temperature, 0.7)

  # Resolve thinking config based on provider, model, and config
  defp thinking_config(%{provider: provider} = state) do
    enabled = Application.get_env(:optimal_system_agent, :thinking_enabled, false)

    if enabled and provider in [:anthropic, nil] and is_anthropic_provider?() do
      model = state.model || Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")

      if String.contains?(to_string(model), "opus") do
        %{type: "adaptive"}
      else
        budget = Application.get_env(:optimal_system_agent, :thinking_budget_tokens, 5_000)
        %{type: "enabled", budget_tokens: budget}
      end
    else
      nil
    end
  end

  defp is_anthropic_provider? do
    default = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
    default == :anthropic
  end

  # Emit context window pressure event so the CLI can display utilization
  defp emit_context_pressure(state) do
    max_tok = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
    estimated = OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
    utilization = if max_tok > 0, do: Float.round(estimated / max_tok * 100, 1), else: 0.0

    Bus.emit(:system_event, %{
      event: :context_pressure,
      session_id: state.session_id,
      estimated_tokens: estimated,
      max_tokens: max_tok,
      utilization: utilization
    })
  rescue
    e -> Logger.debug("emit_context_pressure failed: #{inspect(e)}")
  end

  # Run hooks with fault isolation.
  #
  # Returns {:error, :hooks_unavailable} when the Hooks GenServer is down,
  # rather than {:ok, payload}. This is intentional: pre_tool_use callers
  # MUST fail closed (block execution) when the security pipeline is
  # unreachable. post_tool_use callers may choose to warn and continue.
  defp run_hooks(event, payload) do
    try do
      Hooks.run(event, payload)
    catch
      :exit, reason ->
        Logger.warning("[loop] Hooks GenServer unreachable for #{event} (#{inspect(reason)})")
        {:error, :hooks_unavailable}
    end
  end

  # Async hooks — fire-and-forget for post-event hooks (post_tool_use).
  # Pre-tool hooks stay sync so security_check/spend_guard can block.
  # Logs a warning if the Hooks GenServer is down so the issue is visible,
  # but does not block — post-event side effects are non-critical.
  defp run_hooks_async(event, payload) do
    try do
      Hooks.run_async(event, payload)
    catch
      :exit, reason ->
        Logger.warning("[loop] Hooks GenServer unreachable for async #{event} (#{inspect(reason)})")
        :ok
    end
  end

  # Extract unique tool names used during the agent loop from message history
  defp extract_tools_used(messages) do
    messages
    |> Enum.filter(fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs) and tcs != [] -> true
      _ -> false
    end)
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  # Application-layer guardrail against system prompt extraction attempts.
  # Catches common injection patterns before the LLM processes them,
  # protecting weaker local models (Ollama) that may not follow system instructions.
  #
  # Three-tier detection (all deterministic, no LLM calls):
  #
  #   Tier 1 — Regex on raw trimmed input (fast first pass, < 1ms).
  #   Tier 2 — Regex on *normalized* input: zero-width chars stripped,
  #             fullwidth ASCII folded to ASCII, homoglyphs collapsed,
  #             then lowercased. Catches Unicode obfuscation tricks.
  #   Tier 3 — Structural analysis: detects prompt-boundary markers
  #             injected mid-message (SYSTEM:, ASSISTANT:, XML tags,
  #             markdown instruction headers).

  @injection_patterns [
    ~r/what\s+(is|are|was)\s+(your\s+)?(system\s+prompt|instructions?|rules?|configuration|directives?)/i,
    ~r/what\s+(is|are|was)\s+the\s+(system\s+prompt|instructions?|configuration|directives?)/i,
    ~r/(show(\s+me)?|print|display|reveal|repeat|output|tell\s+me|give\s+me)\s+(your\s+)?(system\s+prompt|instructions?|full\s+prompt|prompt|initial\s+prompt)/i,
    # "tell me your system prompt word for word" and inverted variants
    ~r/tell\s+me\s+.{0,30}(system\s+prompt|instructions?|rules?|prompt)\s*(word\s+for\s+word|verbatim|exactly|literally)?/i,
    ~r/(word\s+for\s+word|verbatim|character\s+for\s+character).{0,40}(prompt|instructions?|told|rules?)/i,
    # "ignore all instructions" without requiring previous/prior/above
    ~r/ignore\s+all\s+(instructions?|rules?|guidelines?|context|constraints?)/i,
    ~r/ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|prompt|context|rules?)/i,
    ~r/repeat\s+everything\s+(above|before|prior)/i,
    ~r/what\s+(were\s+)?(you\s+)?(told|instructed|programmed|trained|configured)\s+to/i,
    # DAN / jailbreak persona adoption
    ~r/(jailbreak|do\s+anything\s+now|developer\s+mode|prompt\s+injection)/i,
    ~r/\byou\s+(are|were|become|act\s+as)\s+DAN\b/i,
    ~r/\bDAN\s+(mode|protocol|activated|enabled)\b/i,
    # "pretend/act as if you have no restrictions"
    ~r/(pretend|act\s+as\s+if|imagine|behave\s+as\s+if)\s+.{0,40}(no\s+restrictions?|no\s+guidelines?|no\s+rules?|unrestricted|without\s+limits?|uncensored)/i,
    # "output everything above/before this"
    ~r/(output|print|repeat|copy|write\s+out)\s+(everything|all\s+text|all\s+content)\s+(above|before|prior)/i,
    ~r/disregard\s+(your\s+)?(previous\s+)?(instructions?|guidelines?|rules?)/i,
    ~r/forget\s+(everything|all)\s+(you\s+)?(were\s+)?(told|instructed|programmed)/i,
    # "override/bypass/circumvent your instructions/restrictions"
    ~r/(override|bypass|circumvent|disable)\s+.{0,30}(instructions?|restrictions?|guidelines?|safety\s+filter)/i
  ]

  # Tier 3 — structural boundary markers that signal injected prompt sections.
  # Anchored to line-starts ((?:^|\n)) so they fire on injected headers,
  # not incidental mid-sentence occurrences.
  @structural_injection_patterns [
    # Role headers on their own line: SYSTEM:, ASSISTANT:, USER:
    ~r/(?:^|\n)\s*(?:system|assistant|user)\s*:/i,
    # Markdown instruction resets: ### New Instructions, ## Override, etc.
    ~r/(?:^|\n)\s*\#{1,6}\s*(?:new\s+instructions?|override|ignore\s+above|reset|updated?\s+rules?)/i,
    # XML-like prompt boundary tags: <system>, </instructions>, <prompt>, etc.
    ~r/<\/?\s*(?:system|instructions?|prompt|context|rules?)\s*>/i,
    # Bracket/chevron-delimited role tags: [SYSTEM], [INST], [/INST], <<SYS>>
    ~r/(?:\[|<<)\s*(?:SYSTEM|INST|SYS|ASSISTANT|USER)\s*(?:\]|>>)/,
    # Horizontal-rule followed by "instructions": ---\nNew instructions below
    ~r/(?:^|\n)-{3,}\s*\n\s*(?:new\s+)?instructions?/i
  ]

  defp prompt_injection?(message) when is_binary(message) do
    trimmed = String.trim(message)

    # Tier 1 — raw regex (fast path, < 1ms)
    if Enum.any?(@injection_patterns, &Regex.match?(&1, trimmed)) do
      true
    else
      # Tier 2 — regex on normalized input (catches Unicode obfuscation)
      normalized = normalize_for_injection_check(trimmed)

      tier2 =
        trimmed != normalized and
          Enum.any?(@injection_patterns, &Regex.match?(&1, normalized))

      if tier2 do
        true
      else
        # Tier 3 — structural boundary analysis
        Enum.any?(@structural_injection_patterns, &Regex.match?(&1, trimmed))
      end
    end
  end

  defp prompt_injection?(_), do: false

  # Normalize user input before Tier 2 injection pattern matching.
  # Eliminates common Unicode obfuscation vectors without touching
  # the original string (Tier 1 always runs on raw input).
  #
  # Steps:
  #   1. Strip zero-width and invisible codepoints (U+200B, ZWNJ, BOM, etc.)
  #   2. Fold fullwidth ASCII (U+FF01–U+FF5E) to standard ASCII (U+0021–U+007E)
  #   3. Collapse common Cyrillic/Greek homoglyphs to ASCII equivalents
  #   4. Lowercase
  defp normalize_for_injection_check(input) when is_binary(input) do
    input
    # Step 1: strip zero-width / invisible codepoints
    |> String.replace(
      ~r/[\x{200B}\x{200C}\x{200D}\x{200E}\x{200F}\x{FEFF}\x{00AD}\x{2028}\x{2029}]/u,
      ""
    )
    # Step 2: fold fullwidth ASCII (！…～, U+FF01–U+FF5E) → standard ASCII (!…~)
    |> String.graphemes()
    |> Enum.map(fn g ->
      case String.to_charlist(g) do
        [cp] when cp >= 0xFF01 and cp <= 0xFF5E -> <<cp - 0xFF01 + 0x21::utf8>>
        _ -> g
      end
    end)
    |> Enum.join()
    # Step 3: collapse common Cyrillic/Greek homoglyphs to ASCII equivalents
    |> String.replace("а", "a")
    |> String.replace("е", "e")
    |> String.replace("о", "o")
    |> String.replace("р", "p")
    |> String.replace("с", "c")
    |> String.replace("х", "x")
    |> String.replace("у", "y")
    |> String.replace("і", "i")
    |> String.replace("ѕ", "s")
    |> String.replace("ν", "v")
    |> String.replace("ο", "o")
    |> String.replace("ρ", "p")
    # Step 4: lowercase
    |> String.downcase()
  end

  # Detect when a local model describes intent ("Let me check...") instead of
  # calling tools. Returns true if the response looks like narrated intent
  # rather than a final answer.
  @intent_patterns [
    ~r/\blet me (check|read|look|examine|create|write|edit|search|find|open|run|list|inspect)\b/i,
    ~r/\bi('ll| will) (check|read|look|create|write|edit|search|find|open|run|list|inspect)\b/i,
    ~r/\bi('m going to|am going to) /i,
    ~r/\bfirst,? i (need|want) to /i,
    ~r/\blet's start by /i,
    ~r/\bnow (i'll|let me|i will|i need to) /i,
    ~r/\bi (need|want) to (check|read|look|examine|create|write|edit|search|find|open|run|list)\b/i
  ]

  # Matches a code block with 5+ lines of content — indicates model wrote code
  # in its response text instead of calling file_write or file_edit.
  @code_block_pattern ~r/```[a-zA-Z]*\n(?:.*\n){5,}?```/

  defp wants_to_continue?(nil), do: false
  defp wants_to_continue?(content) when byte_size(content) < 20, do: false

  defp wants_to_continue?(content) do
    Enum.any?(@intent_patterns, &Regex.match?(&1, content))
  end

  # Detect when model embeds a substantial code block in its response text
  # instead of calling file_write or file_edit to persist it to disk.
  defp code_in_text?(nil), do: false
  defp code_in_text?(content) when byte_size(content) < 50, do: false

  defp code_in_text?(content) do
    Regex.match?(@code_block_pattern, content)
  end

  # Detect when a task involves code changes — triggers the explore-first directive.
  @coding_action_patterns ~r/\b(fix|change|update|refactor|add|implement|create|modify|edit|write|build|rewrite|delete|remove|rename)\b/i
  @coding_context_patterns ~r/\b(function|method|module|file|code|script|class|endpoint|handler|component|route|controller|service|model|schema|migration|test|spec|bug|error|feature)\b/i

  defp complex_coding_task?(message) when is_binary(message) do
    Regex.match?(@coding_action_patterns, message) and
      Regex.match?(@coding_context_patterns, message)
  end

  defp complex_coding_task?(_), do: false

  # Detect when the model issued write/execute tools without any read tools first.
  # Triggered at iteration 1 (first tool batch) to catch blind writes.
  @write_tools ~w(file_write file_edit shell_execute)
  @read_tools ~w(file_read dir_list file_glob file_grep mcts_index)

  defp write_without_read?(tool_calls) do
    names = Enum.map(tool_calls, & &1.name)
    has_write = Enum.any?(names, &(&1 in @write_tools))
    has_read = Enum.any?(names, &(&1 in @read_tools))
    has_write and not has_read
  end
end
