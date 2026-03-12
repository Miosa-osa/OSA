defmodule OptimalSystemAgent.Agent.Loop do
  @moduledoc """
  Bounded ReAct agent loop — the core reasoning engine.

  Messages pass through several pre-LLM gates before the LLM is invoked:

    0. Prompt injection check (Guardrails) — hard block, no memory write
    1. Noise filter (NoiseFilter.check/2) — short-circuit low-signal messages
       before they are persisted or reach the LLM (see Channels.NoiseFilter)
    2. Genre routing (GenreRouter) — route by signal genre; some genres
       return a canned response without tool invocation
    3. Plan mode — single LLM call with no tools (when plan_mode is active)
    4. Full ReAct loop — LLM + iterative tool calls

  Flow:
    1. Receive message from channel/bus
    2. Prompt injection guard (Guardrails.prompt_injection?/1)
    3. Noise filter (NoiseFilter.check/2) — filtered/clarify → return early
    4. Persist user message to memory
    5. Build context (identity + memory + runtime)
    6. Call LLM with available tools
    7. If tool_calls: execute each, append results, re-prompt
    8. When no tool_calls: return final response
    9. Write to memory, notify channel
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Explorer
  alias OptimalSystemAgent.Agent.Memory
  alias OptimalSystemAgent.Agent.Scratchpad
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Channels.NoiseFilter
  alias OptimalSystemAgent.Agent.Strategy

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.GenreRouter

  alias OptimalSystemAgent.Intelligence.ConversationTracker
  alias OptimalSystemAgent.Intelligence.CommCoach
  alias OptimalSystemAgent.Intelligence.ContactDetector
  alias OptimalSystemAgent.Telemetry.Metrics

  defp max_iterations, do: Application.get_env(:optimal_system_agent, :max_iterations, 30)
  defp auto_insights_interval, do: Application.get_env(:optimal_system_agent, :auto_insights_interval, 10)
  defp max_response_tokens, do: Application.get_env(:optimal_system_agent, :max_response_tokens, 8_192)

  # Output-side prompt-leak guard (Bug 17): if a weak model echoed the
  # system prompt despite the input-side block, replace it before returning.
  defp maybe_scrub_prompt_leak(response) do
    if Guardrails.response_contains_prompt_leak?(response) do
      Logger.warning("[loop] Output guardrail: LLM response contained system prompt content — replacing with refusal")
      Guardrails.prompt_extraction_refusal()
    else
      response
    end
  end

  # ETS table for cancel flags — checked each loop iteration.
  # Created in application.ex, written by cancel/1, read by run_loop.
  @cancel_table :osa_cancel_flags

  # Minimum signal weight required to pass a tool list to the LLM.
  # Messages with weight below this threshold get a plain chat call (no tools),
  # preventing hallucinated tool sequences for low-information inputs like "ok" or "lol".
  @tool_weight_threshold 0.20

  defstruct [
    :session_id,
    :user_id,
    :channel,
    :provider,
    :model,
    :working_dir,
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
    last_meta: %{iteration_count: 0, tools_used: []},
    explored_files: MapSet.new(),
    exploration_done: false,
    # :full | :workspace | :read_only
    # Controls which tools the agent is allowed to execute this session.
    permission_tier: :full,
    # Pluggable reasoning strategy (module implementing Strategy behaviour).
    # Defaults to ReAct for backward compatibility.
    strategy: nil,
    # Strategy-specific state managed by the active strategy module.
    strategy_state: %{},
    # Per-call signal weight (0.0–1.0 or nil).
    # Set from :signal_weight opt before entering run_loop.
    # Used to gate tool dispatch: weight < 0.20 → plain chat, no tools.
    signal_weight: nil,
    # UTC datetime when this loop process was initialized.
    started_at: nil
  ]

  # --- Client API ---

  @doc """
  Override child_spec to use `:transient` restart strategy.
  Loop processes should only restart on crash, not on normal exit.
  """
  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    user_id = Keyword.get(opts, :user_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id, user_id}})
  end

  def process_message(session_id, message, opts \\ []) do
    GenServer.call(via(session_id), {:process, message, opts}, :infinity)
  end

  @doc "Get metadata from the last process_message call (iteration_count, tools_used)."
  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  catch
    :exit, _ -> {:error, :not_found}
  end

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
    session_id = Keyword.fetch!(opts, :session_id)

    # Attempt checkpoint restore — if this session crashed, pick up where it left off
    restored = Checkpoint.restore_checkpoint(session_id)

    messages = Keyword.get(opts, :messages) || Map.get(restored, :messages, [])
    iteration = Map.get(restored, :iteration, 0)
    plan_mode = Map.get(restored, :plan_mode, false)
    turn_count = Map.get(restored, :turn_count, 0)

    state = %__MODULE__{
      session_id: session_id,
      user_id: Keyword.get(opts, :user_id),
      channel: Keyword.get(opts, :channel, :cli),
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      messages: messages,
      iteration: iteration,
      plan_mode: plan_mode,
      turn_count: turn_count,
      tools: Tools.filter_applicable_tools(%{history: []}) ++ extra_tools,
      plan_mode_enabled: Application.get_env(:optimal_system_agent, :plan_mode_enabled, false),
      permission_tier: Keyword.get(opts, :permission_tier, :full),
      working_dir: Keyword.get(opts, :working_dir) || Application.get_env(:optimal_system_agent, :working_dir)
    }

    # Resolve reasoning strategy — explicit opt, task_type, or default to ReAct
    strategy_context =
      case {Keyword.get(opts, :strategy), Keyword.get(opts, :task_type)} do
        {name, _} when is_atom(name) and not is_nil(name) -> %{strategy: name}
        {_, task_type} when is_atom(task_type) and not is_nil(task_type) -> %{task_type: task_type}
        _ -> %{}
      end

    {strategy_mod, strategy_state} =
      case Strategy.resolve(strategy_context) do
        {:ok, mod} -> {mod, mod.init_state(strategy_context)}
        {:error, _} ->
          # Fallback to ReAct
          react = OptimalSystemAgent.Agent.Strategies.ReAct
          {react, react.init_state(%{})}
      end

    state = %{state | strategy: strategy_mod, strategy_state: strategy_state, started_at: DateTime.utc_now()}

    if restored != %{} do
      Logger.info("[loop] Restored checkpoint for session #{session_id} — iteration=#{iteration}, messages=#{length(messages)}")
    end

    # Vault wake — detect dirty deaths, set dirty flag
    try do
      OptimalSystemAgent.Vault.wake(session_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

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

    # Re-resolve strategy per-message using actual message content and available tools.
    # init/1 runs before any message arrives so it cannot infer task type from content.
    # Here we have the message, so we build a proper context and let select?/1 run.
    state = maybe_update_strategy(state, message, opts)

    # 0. Clear per-message caches (git info and workspace overview run once per message, not per iteration)
    Process.delete(:osa_git_info_cache)
    Process.delete(:osa_workspace_overview_cache)

    # Clear system message cache at start of each process call (Phase 4)
    Process.delete(:osa_system_msg_cache)
    Process.put(:osa_memory_version, 0)

    # 0.5. Application-layer prompt injection guard — block before LLM ever sees it.
    # This catches weak local models (Ollama) that ignore system prompt instructions.
    if Guardrails.prompt_injection?(message) do
      refusal = Guardrails.prompt_extraction_refusal()
      Memory.append(state.session_id, %{role: "user", content: message, channel: state.channel})
      Memory.append(state.session_id, %{role: "assistant", content: refusal, channel: state.channel})
      state = %{state | status: :idle}
      {:reply, {:ok, refusal}, state}
    else

    # 1. Noise filter — intercept low-signal messages before persisting or reaching the LLM.
    # Check noise FIRST so filtered messages ("ok", "lol") are never written to memory.
    # signal_weight comes from an upstream classifier (e.g. HTTP handler that called
    # /api/v1/classify first). Defaults to nil (no weight check, Tier 1 regex only).
    signal_weight = Keyword.get(opts, :signal_weight, nil)

    # Store weight on state so run_loop / do_run_loop can gate tool dispatch.
    state = %{state | signal_weight: signal_weight}

    noise_result = NoiseFilter.check(message, signal_weight)

    if noise_result != :pass do
      {outcome, ack} =
        case noise_result do
          {:filtered, ack} -> {:filtered, ack}
          {:clarify, prompt} -> {:clarify, prompt}
        end

      # Instrument the noise filter result so Telemetry.Metrics tracks filter rate.
      # This call is fire-and-forget via GenServer.cast — never blocks the loop.
      try do
        Metrics.record_noise_filter_result(outcome)
      rescue
        _ -> :ok
      end

      state = %{state | status: :idle}
      {:reply, {:ok, ack}, state}
    else
      # Record :pass so the denominator is correct in noise_filter_rate calculations.
      try do
        Metrics.record_noise_filter_result(:pass)
      rescue
        _ -> :ok
      end

    # 1.5. Persist user message to JSONL session storage (only non-noise messages)
    Memory.append(state.session_id, %{role: "user", content: message, channel: state.channel})

    # 1.6. Intelligence wiring — track conversation depth and detect contacts.
    # Both run in a fire-and-forget task so they never block the agent loop.
    session_id = state.session_id
    channel = state.channel
    Task.start(fn ->
      try do
        ConversationTracker.record_turn(session_id, message)
      rescue
        e -> Logger.debug("[loop] ConversationTracker.record_turn failed: #{inspect(e)}")
      end

      contacts = ContactDetector.detect(message)
      if contacts != [] do
        Bus.emit(:system_event, %{
          event: :contacts_detected,
          session_id: session_id,
          channel: channel,
          contacts: contacts
        })
      end
    end)

    # 2. Compact message history if needed, then process through agent loop
    compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages) || state.messages
    state = %{state | messages: compacted}

    # Auto-extract insights from recent conversation history every 10 turns.
    # This runs silently — no user-visible output.
    interval = auto_insights_interval()
    if rem(state.turn_count, interval) == 0 and state.turn_count > 0 do
      recent = Enum.take(state.messages, -20)
      Task.start(fn -> Memory.extract_insights(recent) end)
    end

    # Memory nudge every N turns (Phase 6)
    # After complex tasks (>5 turns), also check for unsaved patterns to suggest saving.
    message_with_nudge =
      cond do
        rem(state.turn_count, interval) == 0 and state.turn_count > 0 ->
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
      if Guardrails.complex_coding_task?(message_with_nudge) do
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
        status: :thinking,
        exploration_done: false
    }

    # 2.5. Auto-explore codebase before ReAct loop (if message looks like a code task)
    # Pass raw message, not message_with_nudge, so heuristic operates on user intent only
    state = case Explorer.maybe_explore(state, message) do
      {:explored, new_state} -> new_state
      {:skip, s} -> s
    end

    # 2.6. Genre routing — adjust behavior based on signal type when provided by caller.
    # Callers that pre-classify messages pass :signal_genre in opts.
    # Defaults to :direct (current behavior: execute tools immediately).
    signal_genre = Keyword.get(opts, :signal_genre, :direct)

    genre_route = GenreRouter.route_by_genre(signal_genre, message, state)

    case genre_route do
      {:respond, genre_response} ->
        Memory.append(state.session_id, %{role: "assistant", content: genre_response, channel: state.channel})
        state = %{state | status: :idle}
        Bus.emit(:agent_response, %{session_id: state.session_id, response: genre_response, agent: state.session_id})
        {:reply, {:ok, genre_response}, state}

      :execute_tools ->

    # 3. Check if plan mode should trigger
    if not skip_plan and should_plan?(state) do
      # Plan mode: single LLM call with plan overlay, no tools
      state = %{state | plan_mode: true}
      context = Context.build(state)

      Bus.emit(:llm_request, %{session_id: state.session_id, iteration: 0})
      start_time = System.monotonic_time(:millisecond)

      result = LLMClient.llm_chat(state, context.messages, tools: [], temperature: 0.3)

      duration_ms = System.monotonic_time(:millisecond) - start_time

      usage =
        case result do
          {:ok, resp} -> Map.get(resp, :usage, %{})
          _ -> %{}
        end

      Bus.emit(:llm_response, %{
        session_id: state.session_id,
        provider: state.provider,
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

          response = maybe_scrub_prompt_leak(response)

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

      response = maybe_scrub_prompt_leak(response)

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

  def handle_call(:get_state, _from, state) do
    uptime = if state.started_at, do: DateTime.diff(DateTime.utc_now(), state.started_at), else: 0
    snap = %{session_id: state.session_id, iteration: state.iteration, tokens_used: estimate_tokens_for_introspection(state), tools_called: state.last_meta[:tools_used] || [], status: state.status, started_at: state.started_at, uptime_seconds: uptime, provider: state.provider, model: state.model}
    {:reply, {:ok, snap}, state}
  end

  @impl true
  def handle_call({:swap_provider, provider, model}, _from, state) do
    {:reply, :ok, %{state | provider: provider, model: model}}
  end

  @impl true
  def handle_call(:toggle_plan_mode, _from, state) do
    new_val = not state.plan_mode_enabled
    {:reply, {:ok, new_val}, %{state | plan_mode_enabled: new_val}}
  end

  def handle_call({:set_permission_tier, tier}, _from, state)
      when tier in [:full, :workspace, :read_only] do
    {:reply, {:ok, tier}, %{state | permission_tier: tier}}
  end

  def handle_call({:get_permission_tier}, _from, state) do
    {:reply, {:ok, state.permission_tier}, state}
  end

  def handle_call({:set_strategy, strategy_name}, _from, state) when is_atom(strategy_name) do
    case Strategy.resolve_by_name(strategy_name) do
      {:ok, mod} ->
        new_state = %{state | strategy: mod, strategy_state: mod.init_state(%{})}
        Bus.emit(:strategy_changed, %{
          session_id: state.session_id,
          from: (state.strategy && state.strategy.name()) || :none,
          to: mod.name()
        })
        {:reply, {:ok, mod.name()}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_strategy, _from, state) do
    name = if state.strategy, do: state.strategy.name(), else: :none
    {:reply, {:ok, name, state.strategy_state}, state}
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

    # ── Strategy guidance ────────────────────────────────────────────
    # Consult the active strategy before calling the LLM. The strategy can:
    #   - inject a reasoning guidance message into the context
    #   - signal completion ({:done, ...}) to short-circuit
    #   - request a strategy switch
    {context, state} =
      if state.strategy do
        loop_context = %{
          iteration: state.iteration,
          messages: state.messages,
          task: last_user_message(state.messages)
        }

        case state.strategy.next_step(state.strategy_state, loop_context) do
          {{:done, info}, new_ss} ->
            # Strategy says we're done — but we still let the LLM produce a final
            # response by adding a summarization hint rather than short-circuiting.
            hint = Map.get(info, :summary, "Summarize your findings and respond.")
            guidance = %{role: "system", content: "[Strategy/#{state.strategy.name()}] #{hint}"}
            {%{context | messages: context.messages ++ [guidance]},
             %{state | strategy_state: new_ss}}

          {{:think, thought}, new_ss} ->
            guidance = %{
              role: "system",
              content: "[Strategy/#{state.strategy.name()}] #{thought}"
            }
            {%{context | messages: context.messages ++ [guidance]},
             %{state | strategy_state: new_ss}}

          {{:act, _, _}, new_ss} ->
            # Act phase — no extra guidance, let the LLM pick tools naturally
            {context, %{state | strategy_state: new_ss}}

          {{:observe, observation}, new_ss} ->
            guidance = %{
              role: "system",
              content: "[Strategy/#{state.strategy.name()}] #{observation}"
            }
            {%{context | messages: context.messages ++ [guidance]},
             %{state | strategy_state: new_ss}}

          {{:respond, text}, new_ss} ->
            guidance = %{
              role: "system",
              content: "[Strategy/#{state.strategy.name()}] #{text}"
            }
            {%{context | messages: context.messages ++ [guidance]},
             %{state | strategy_state: new_ss}}

          _other ->
            {context, state}
        end
      else
        {context, state}
      end

    # Emit timing event before LLM call
    Bus.emit(:llm_request, %{session_id: state.session_id, iteration: state.iteration})
    start_time = System.monotonic_time(:millisecond)

    # Call LLM with streaming — emits per-token SSE events for live TUI display.
    # Falls back to sync chat if streaming is unavailable.
    thinking_opts = LLMClient.thinking_config(state)

    # Weight gate (Bug 9): if the caller supplied a signal weight below 0.20,
    # the message is low-information ("ok", "lol", single emoji, etc.).
    # Sending a full tool list for such inputs triggers hallucinated tool calls.
    # Skip tools entirely and do a plain chat call instead.
    tools_for_call =
      if is_number(state.signal_weight) and state.signal_weight < @tool_weight_threshold do
        Logger.debug("[loop] signal_weight=#{state.signal_weight} < #{@tool_weight_threshold} — skipping tools for low-weight input")
        []
      else
        state.tools
      end

    llm_opts = [tools: tools_for_call, temperature: LLMClient.temperature(), max_tokens: max_response_tokens()]
    llm_opts = if thinking_opts, do: Keyword.put(llm_opts, :thinking, thinking_opts), else: llm_opts
    # LLM streaming call — idle-timeout detection is inside LLMClient.
    # Active streams can run indefinitely; only silent connections are killed.
    result = LLMClient.llm_chat_stream(state, context.messages, llm_opts)

    # Emit timing + usage event after LLM call
    duration_ms = System.monotonic_time(:millisecond) - start_time

    usage =
      case result do
        {:ok, resp} -> Map.get(resp, :usage, %{})
        _ -> %{}
      end

    Bus.emit(:llm_response, %{
      session_id: state.session_id,
      provider: state.provider,
      duration_ms: duration_ms,
      usage: usage
    })

    case result do
      {:ok, %{content: content, tool_calls: []}} ->
        # No tool calls — final response. Guard empty content (Bug 27: Unicode messages
        # from small local models sometimes return whitespace-only responses).
        content = if is_nil(content) or String.trim(content) == "", do: "...", else: content

        # Scratchpad: extract <think> blocks for non-Anthropic providers
        content =
          if Scratchpad.inject?(state.provider) do
            Scratchpad.process_response(content, state.session_id)
          else
            content
          end

        # Re-guard after scratchpad extraction (thinking-only responses)
        content = if String.trim(content) == "", do: "...", else: content

        cond do
          state.auto_continues < 2 and Guardrails.wants_to_continue?(content) ->
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

          state.auto_continues < 3 and Guardrails.code_in_text?(content) ->
            Logger.info("[loop] Coding nudge: model wrote code in markdown instead of calling file_write/file_edit (nudge #{state.auto_continues + 1}/3)")
            nudge = %{
              role: "system",
              content: "[CRITICAL: You wrote code in markdown instead of using a tool. " <>
                "You MUST call file_write with the code as content to create the file. " <>
                "Do NOT output code in your response text — call the file_write tool NOW.]"
            }
            state = %{state |
              messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
              auto_continues: state.auto_continues + 1,
              iteration: state.iteration + 1
            }
            run_loop(state)

          Guardrails.needs_verification_gate?(state) ->
            Logger.info("[loop] Verification gate: iteration #{state.iteration}, task context present, zero successful tools — injecting verification")
            verification = %{
              role: "system",
              content: "[System: VERIFICATION REQUIRED — You completed #{state.iteration} iterations with a task/goal " <>
                "but executed zero tools successfully. Before returning a final response, verify your answer: " <>
                "use at least one tool (e.g. file_read, dir_list, shell_execute) to confirm your response is accurate. " <>
                "Do NOT return a final answer without tool-backed evidence.]"
            }
            state = %{state |
              messages: state.messages ++ [%{role: "assistant", content: content}, verification],
              iteration: state.iteration + 1,
              # Burn the auto_continues budget so this fires at most once
              auto_continues: 2
            }
            run_loop(state)

          true ->
            # CommCoach: score the outbound response async — observe only, never blocks.
            score_session_id = state.session_id
            score_channel = state.channel
            score_user_id = state.user_id
            score_content = content
            Task.start(fn ->
              try do
                case CommCoach.score_response(score_content, score_user_id, score_channel) do
                  {:ok, %{verdict: verdict, score: score, suggestions: suggestions}}
                  when verdict in [:needs_work, :poor] ->
                    Bus.emit(:system_event, %{
                      event: :comm_coach_warning,
                      session_id: score_session_id,
                      verdict: verdict,
                      score: score,
                      suggestions: suggestions
                    })
                    Logger.warning("[CommCoach] outbound quality #{verdict} (#{score}) session=#{score_session_id}")

                  _ ->
                    :ok
                end
              rescue
                e -> Logger.debug("[loop] CommCoach.score_response failed: #{inspect(e)}")
              end
            end)

            {content, state}
        end

      {:ok, %{content: content, tool_calls: tool_calls} = resp} when is_list(tool_calls) ->
        # Execute tool calls
        state = %{state | iteration: state.iteration + 1}

        # Scratchpad: strip <think> blocks from assistant content in tool-call responses
        content =
          if Scratchpad.inject?(state.provider) do
            Scratchpad.process_response(content, state.session_id)
          else
            content
          end

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

        # Append all tool messages in original order
        tool_messages = Enum.map(results, fn {_tc, {tool_msg, _result_str}} -> tool_msg end)
        state = %{state | messages: state.messages ++ tool_messages}

        # Checkpoint after tool results — crash recovery can resume from here
        Checkpoint.checkpoint_state(state)

        # ── Strategy: handle tool results ──────────────────────────────
        # Update strategy state with tool outcomes so the strategy can track
        # progress (e.g., count observations, detect patterns).
        state =
          if state.strategy do
            result_summary = Enum.map(results, fn {tc, {_msg, result_str}} ->
              %{tool: tc.name, result: result_str}
            end)

            new_ss = state.strategy.handle_result(
              {:act, :tools, %{tool_calls: tool_calls}},
              result_summary,
              state.strategy_state
            )

            # Check for strategy switch request
            case new_ss do
              {:switch_strategy, new_name} ->
                case Strategy.resolve_by_name(new_name) do
                  {:ok, new_mod} ->
                    Logger.info("[loop] Strategy switch: #{state.strategy.name()} -> #{new_mod.name()}")
                    Bus.emit(:strategy_changed, %{
                      session_id: state.session_id,
                      from: state.strategy.name(),
                      to: new_mod.name()
                    })
                    %{state | strategy: new_mod, strategy_state: new_mod.init_state(%{})}

                  {:error, _} ->
                    Logger.warning("[loop] Strategy switch failed: unknown strategy #{inspect(new_name)}")
                    state
                end

              new_ss when is_map(new_ss) ->
                %{state | strategy_state: new_ss}

              _ ->
                state
            end
          else
            state
          end

        # Read-before-write nudge — check if any file_edit/file_write targeted an unread file
        state = ToolExecutor.inject_read_nudges(state, tool_calls)

        # If memory_save ran successfully in this batch, invalidate system message cache (Phase 4)
        if Enum.any?(tool_calls, fn tc -> tc.name == "memory_save" end) and
             Enum.any?(results, fn {tc, {_msg, result_str}} ->
               tc.name == "memory_save" and not String.starts_with?(result_str, "Error:")
             end) do
          Process.put(:osa_memory_version, Process.get(:osa_memory_version, 0) + 1)
        end

        # Explore-first nudge — if the model edits existing files without reading first at iteration 1.
        # Only fires when file_edit or shell_execute are used (modifying existing code).
        # Does NOT fire for pure file_write (creating new files) — there's nothing to read first.
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

  defp context_overflow?(reason) do
    String.contains?(reason, "context_length") or
      String.contains?(reason, "max_tokens") or
      String.contains?(reason, "maximum context length") or
      String.contains?(reason, "token limit")
  end

  # Extract the last user message from conversation history for strategy context.
  defp last_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: c} when is_binary(c) -> c
      _ -> nil
    end)
  end

  # Clean up checkpoint on normal exit — only crash restarts should use it
  @impl true
  def terminate(:normal, state) do
    Checkpoint.clear_checkpoint(state.session_id)
    vault_sleep(state.session_id)
    :ok
  end

  def terminate(:shutdown, state) do
    Checkpoint.clear_checkpoint(state.session_id)
    vault_sleep(state.session_id)
    :ok
  end

  def terminate({:shutdown, _}, state) do
    Checkpoint.clear_checkpoint(state.session_id)
    vault_sleep(state.session_id)
    :ok
  end

  def terminate(_reason, _state) do
    # Abnormal termination — keep checkpoint for recovery
    # Dirty flag stays for next wake to detect
    :ok
  end

  defp vault_sleep(session_id) do
    try do
      OptimalSystemAgent.Vault.sleep(session_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # --- Plan Mode ---

  defp should_plan?(state) do
    # Plan mode triggers when explicitly enabled by the user.
    # The skip_plan: true opt (passed by CLI on approved plan execution)
    # bypasses this check entirely at the handle_call level.
    # The LLM decides whether the message warrants a plan via prompt instructions.
    state.plan_mode_enabled and not state.plan_mode
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

  # Emit context window pressure event so the CLI can display utilization
  defp emit_context_pressure(state) do
    max_tok = MiosaProviders.Registry.context_window(state.model)
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

  defp estimate_tokens_for_introspection(state) do
    try do
      OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
    rescue
      _ -> 0
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

  # Re-resolve the reasoning strategy based on the incoming message content.
  #
  # This runs at the start of every handle_call so that strategy selection has
  # access to the actual user message (not available at init/1 time). If the
  # caller explicitly passed a :strategy or :task_type opt, those take priority.
  # Otherwise we infer task_type from message keywords and compute a complexity
  # score so that select?/1 on each strategy can actually fire.
  defp maybe_update_strategy(state, message, opts) do
    # Explicit caller opt always wins — don't override a deliberate choice.
    case {Keyword.get(opts, :strategy), Keyword.get(opts, :task_type)} do
      {name, _} when is_atom(name) and not is_nil(name) ->
        state

      {_, task_type} when is_atom(task_type) and not is_nil(task_type) ->
        state

      _ ->
        # Infer task context from message content
        inferred = infer_task_context(message, state.tools)

        case Strategy.resolve(inferred) do
          {:ok, mod} when mod != state.strategy ->
            Logger.debug("[loop] Strategy switched #{inspect(state.strategy && state.strategy.name())} -> #{mod.name()} for message")
            %{state | strategy: mod, strategy_state: mod.init_state(inferred)}

          {:ok, _same} ->
            state
        end
    end
  end

  # Build a strategy context map from raw message content.
  #
  # task_type — keyword-based classification. One pass over the message
  # covers the most common patterns; order matters (more specific first).
  #
  # complexity — heuristic: word count bucketed 1-10.
  defp infer_task_context(message, tools) do
    lower = String.downcase(message)
    words = String.split(message)
    word_count = length(words)

    task_type =
      cond do
        Regex.match?(~r/\b(debug|fix bug|traceback|error|exception|crash|failing|broken)\b/, lower) ->
          :debugging

        Regex.match?(~r/\b(review|audit|check|inspect|critique|assess|evaluate)\b/, lower) ->
          :review

        Regex.match?(~r/\b(refactor|clean up|reorganize|restructure|rename|extract|simplify)\b/, lower) ->
          :refactor

        Regex.match?(~r/\b(design|architect|plan|blueprint|spec|diagram|system design)\b/, lower) ->
          :design

        Regex.match?(~r/\b(planning|roadmap|strategy|approach|how should i|what's the best way)\b/, lower) ->
          :planning

        Regex.match?(~r/\b(analyze|analyse|research|explain|describe|understand|how does)\b/, lower) ->
          :analysis

        Regex.match?(~r/\b(explore|discover|find the best|optimize|search for|what if)\b/, lower) ->
          :exploration

        Regex.match?(~r/\b(optimize|performance|faster|slower|bottleneck|benchmark)\b/, lower) ->
          :optimization

        true ->
          :action
      end

    # Word count → complexity score 1-10
    complexity =
      cond do
        word_count < 10 -> 1
        word_count < 20 -> 2
        word_count < 40 -> 3
        word_count < 60 -> 4
        word_count < 80 -> 5
        word_count < 120 -> 6
        word_count < 200 -> 7
        word_count < 300 -> 8
        word_count < 500 -> 9
        true -> 10
      end

    tool_names = Enum.map(tools, fn
      %{name: n} -> n
      t when is_atom(t) -> t
      t when is_binary(t) -> t
      _ -> nil
    end) |> Enum.reject(&is_nil/1)

    %{
      task_type: task_type,
      complexity: complexity,
      tools: tool_names,
      message: message,
      task: message
    }
  end

  # Apply per-call overrides from opts (SDK query passthrough)
  defp apply_overrides(state, opts) do
    state
    |> maybe_override(:provider, Keyword.get(opts, :provider))
    |> maybe_override(:model, Keyword.get(opts, :model))
    |> maybe_override(:working_dir, Keyword.get(opts, :working_dir))
  end

  defp maybe_override(state, _key, nil), do: state
  defp maybe_override(state, key, value), do: Map.put(state, key, value)

  # --- Ask User Question (Survey Dialog) ---

  @survey_table :osa_survey_answers

  @doc """
  Ask the user interactive questions via the TUI survey dialog.
  Blocks the calling process until the user responds or timeout (120s).

  Returns `{:ok, answers}` | `{:skipped}` | `{:error, :timeout}` | `{:error, :cancelled}`.

  ## Question format

      %{
        text: "Which editor do you use most?",
        multi_select: false,
        options: [
          %{label: "Neovim", description: "Fast keyboard-driven workflow"},
          %{label: "VS Code", description: "Feature-rich and extensible"}
        ],
        skippable: true
      }
  """
  @spec ask_user_question(String.t(), String.t(), list(map()), keyword()) ::
          {:ok, term()} | {:skipped} | {:error, :timeout} | {:error, :cancelled}
  def ask_user_question(session_id, survey_id, questions, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    # Emit SSE event for TUI to display the survey dialog
    Bus.emit(:system_event, %{
      event: :ask_user_question,
      session_id: session_id,
      data: %{
        survey_id: survey_id,
        questions: questions,
        skippable: Keyword.get(opts, :skippable, true)
      }
    })

    # Poll ETS for response
    poll_survey_answer(session_id, survey_id, timeout)
  end

  defp poll_survey_answer(_session_id, _survey_id, timeout) when timeout <= 0 do
    {:error, :timeout}
  end

  defp poll_survey_answer(session_id, survey_id, timeout) do
    # Check if session was cancelled
    case :ets.lookup(@cancel_table, session_id) do
      [{_, true}] ->
        {:error, :cancelled}

      _ ->
        key = {session_id, survey_id}

        case :ets.lookup(@survey_table, key) do
          [{^key, :skipped}] ->
            :ets.delete(@survey_table, key)
            {:skipped}

          [{^key, answers}] ->
            :ets.delete(@survey_table, key)
            {:ok, answers}

          [] ->
            Process.sleep(200)
            poll_survey_answer(session_id, survey_id, timeout - 200)
        end
    end
  end

  # --- Delegations for backward compatibility ---
  # These public functions were previously defined directly in this module.
  # They delegate to the extracted modules so any external callers continue to work.

  @doc false
  defdelegate checkpoint_state(state), to: Checkpoint

  @doc false
  defdelegate restore_checkpoint(session_id), to: Checkpoint

  @doc false
  defdelegate clear_checkpoint(session_id), to: Checkpoint

  @doc false
  defdelegate needs_verification_gate?(state), to: Guardrails

  @doc false
  defdelegate permission_tier_allows?(tier, tool), to: ToolExecutor
end
