defmodule OptimalSystemAgent.Agent.Loop do
  @moduledoc """
  Bounded ReAct agent loop — the core reasoning engine.

  Signal Theory grounded: Every iteration processes one signal through
  the 5-tuple S=(M,G,T,F,W) classification before acting.

  Flow:
    1. Receive message from channel/bus
    2. Classify signal (Mode, Genre, Type, Format, Weight)
    3. Filter noise (two-tier: deterministic + LLM)
    4. Build context (identity + memory + skills + runtime)
    5. Call LLM with available tools
    6. If tool_calls: execute each, append results, re-prompt
    7. When no tool_calls: return final response
    8. Write to memory, notify channel
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Signal.Classifier
  alias OptimalSystemAgent.Signal.NoiseFilter
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus

  defp max_iterations, do: Application.get_env(:optimal_system_agent, :max_iterations, 30)

  defstruct [
    :session_id,
    :user_id,
    :channel,
    :current_signal,
    :provider,
    :model,
    messages: [],
    iteration: 0,
    status: :idle,
    tools: [],
    plan_mode: false,
    plan_mode_enabled: false,
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

    # Apply per-call provider/model overrides (SDK passthrough)
    state = apply_overrides(state, opts)

    # 0. Clear per-message caches (git info runs once per message, not per iteration)
    Process.delete(:osa_git_info_cache)

    # 1. Classify the signal — deterministic fast path (<1ms), async LLM enrichment in background
    signal = Classifier.classify_fast(message, state.channel)
    Classifier.classify_async(message, state.channel, state.session_id)

    # 2. Check noise filter — gate low-signal messages to avoid wasting LLM calls
    case NoiseFilter.filter(message) do
      {:noise, reason} ->
        Logger.debug("Signal classified as noise (#{reason}), weight=#{signal.weight}")
        Bus.emit(:system_event, %{event: :signal_low_weight, signal: signal, reason: reason})

        # Persist to session but don't invoke LLM
        Memory.append(state.session_id, %{role: "user", content: message, channel: state.channel})
        ack = noise_acknowledgment(reason)
        Memory.append(state.session_id, %{role: "assistant", content: ack, channel: state.channel})
        state = %{state | status: :idle}
        {:reply, {:ok, ack}, state}

      {:signal, _weight} ->
        # 3. Persist user message to JSONL session storage
        Memory.append(state.session_id, %{role: "user", content: message, channel: state.channel})

        # 4. Compact message history if needed, then process through agent loop
        compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
        state = %{state | messages: compacted, current_signal: signal}

        state = %{
          state
          | messages: state.messages ++ [%{role: "user", content: message}],
            iteration: 0,
            status: :thinking
        }

        # 5. Check if plan mode should trigger
        if not skip_plan and should_plan?(signal, state) do
          # Plan mode: single LLM call with plan overlay, no tools
          state = %{state | plan_mode: true}
          context = Context.build(state, signal)

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
              {:reply, {:plan, plan_text, signal}, state}

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
                response: response,
                signal: signal
              })

              {:reply, {:ok, response}, state}
          end
        else
          # Normal execution path
          {response, state} = run_loop(state)

          meta = %{iteration_count: state.iteration, tools_used: extract_tools_used(state.messages)}

          state = %{
            state
            | messages: state.messages ++ [%{role: "assistant", content: response}],
              status: :idle,
              last_meta: meta
          }

          # 6. Persist assistant response to JSONL session storage
          Memory.append(state.session_id, %{role: "assistant", content: response, channel: state.channel})

          emit_context_pressure(state)

          Bus.emit(:agent_response, %{
            session_id: state.session_id,
            response: response,
            signal: signal
          })

          {:reply, {:ok, response}, state}
        end
    end
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

  defp run_loop(%{iteration: iter} = state) do
    max_iter = max_iterations()

    if iter >= max_iter do
      Logger.warning("Agent loop hit max iterations (#{max_iter})")
      {"I've reached my reasoning limit for this request. Here's what I have so far.", state}
    else
      do_run_loop(state)
    end
  end

  defp do_run_loop(state) do
    # Build context (passes current signal for signal-aware system prompt)
    context = Context.build(state, state.current_signal)

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
        # No tool calls — final response
        {content, state}

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

        # Execute each tool and append results (with timing feedback)
        state =
          Enum.reduce(tool_calls, state, fn tool_call, acc ->
            arg_hint = tool_call_hint(tool_call.arguments)
            Bus.emit(:tool_call, %{name: tool_call.name, phase: :start, args: arg_hint, session_id: acc.session_id})
            start_time_tool = System.monotonic_time(:millisecond)

            # Run pre_tool_use hooks (budget guard, security check, etc.)
            pre_payload = %{
              tool_name: tool_call.name,
              arguments: tool_call.arguments,
              session_id: acc.session_id
            }

            tool_result =
              case run_hooks(:pre_tool_use, pre_payload) do
                {:blocked, reason} ->
                  "Blocked: #{reason}"

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

            # Normalize result for hooks/events (images get a text summary)
            result_str =
              case tool_result do
                {:image, _mt, _b64, path} -> "[image: #{path}]"
                text when is_binary(text) -> text
                other -> inspect(other)
              end

            # Run post_tool_use hooks (cost tracker, telemetry, learning, etc.)
            post_payload = %{
              tool_name: tool_call.name,
              result: result_str,
              duration_ms: tool_duration_ms,
              session_id: acc.session_id
            }

            run_hooks_async(:post_tool_use, post_payload)

            Bus.emit(:tool_call, %{
              name: tool_call.name,
              phase: :end,
              duration_ms: tool_duration_ms,
              args: arg_hint,
              session_id: acc.session_id
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
                  %{role: "tool", tool_call_id: tool_call.id, content: result_str}
              end

            %{acc | messages: acc.messages ++ [tool_msg]}
          end)

        # Re-prompt
        run_loop(state)

      {:error, reason} ->
        reason_str = if is_binary(reason), do: reason, else: inspect(reason)

        if context_overflow?(reason_str) and state.iteration < 3 do
          Logger.warning("Context overflow — compacting and retrying (attempt #{state.iteration + 1})")
          compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
          state = %{state | messages: compacted, iteration: state.iteration + 1}
          run_loop(state)
        else
          if context_overflow?(reason_str) do
            Logger.error("Context overflow after 3 compaction attempts")
            {"I've exceeded the context window. Try breaking your request into smaller parts.", state}
          else
            Logger.error("LLM call failed: #{reason_str}")
            {"I encountered an error processing your request. Please try again.", state}
          end
        end
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
        Bus.emit(:system_event, %{
          event: :streaming_token,
          session_id: session_id,
          text: text
        })

      {:done, result} ->
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

  defp should_plan?(signal, state) do
    # Plan mode triggers for high-weight action signals only.
    # The skip_plan: true opt (passed by CLI on approved plan execution)
    # bypasses this check entirely at the handle_call level.
    # :analyze excluded — read-only tasks don't benefit from plan approval.
    state.plan_mode_enabled and
      not state.plan_mode and
      signal.mode in [:build, :execute, :maintain] and
      signal.weight >= 0.75 and
      signal.type in ["request", "general"]
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
    _ -> :ok
  end

  # Run hooks with fault isolation — never crash the loop if hooks are down
  defp run_hooks(event, payload) do
    try do
      Hooks.run(event, payload)
    catch
      :exit, _ -> {:ok, payload}
    end
  end

  # Async hooks — fire-and-forget for post-event hooks (post_tool_use).
  # Pre-tool hooks stay sync so security_check/spend_guard can block.
  defp run_hooks_async(event, payload) do
    try do
      Hooks.run_async(event, payload)
    catch
      :exit, _ -> :ok
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

  # --- Noise Acknowledgments ---
  # Minimal responses for noise-classified messages (no LLM call needed)
  defp noise_acknowledgment(:empty), do: ""
  defp noise_acknowledgment(:too_short), do: "\u{1F44D}"
  defp noise_acknowledgment(:pattern_match), do: "\u{1F44D}"
  defp noise_acknowledgment(:low_weight), do: "Got it."
  defp noise_acknowledgment(:llm_classified), do: "Noted."
  defp noise_acknowledgment(_), do: "\u{1F44D}"
end
