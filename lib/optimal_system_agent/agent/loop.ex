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
  alias OptimalSystemAgent.Agent.Scratchpad
  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus
  # NoiseFilter disabled (Fix #57) — alias removed

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.GenreRouter

  defp max_iterations, do: Application.get_env(:optimal_system_agent, :max_iterations, 30)
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

  # Output-side dead-phrase guard: strip corporate filler that weaker models
  # produce despite the system prompt banning them.
  defp maybe_strip_dead_phrases(response) when is_binary(response) do
    if Guardrails.contains_dead_phrase?(response) do
      Logger.info("[loop] Output guardrail: stripping dead phrases from response")
      Guardrails.strip_dead_phrases(response)
    else
      response
    end
  end

  defp maybe_strip_dead_phrases(response), do: response

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
    # :full | :workspace | :read_only | :subagent
    # Controls which tools the agent is allowed to execute this session.
    permission_tier: :full,
    # Subagent fields — set when this Loop is spawned by the delegate tool.
    # parent_session_id routes events back to the parent's SSE stream.
    parent_session_id: nil,
    # Per-agent tool restrictions from AGENT.md definition.
    allowed_tools: nil,
    blocked_tools: [],
    # Override system prompt with agent-specific instructions (from AGENT.md).
    system_prompt_override: nil,
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
    started_at: nil,
    # Actual input token count from the last LLM call (for context pressure).
    last_input_tokens: 0
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
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(via(session_id), {:process, message, opts}, timeout)
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

    # Also cancel any sub-agents spawned by this session.
    # Sub-agent IDs follow the pattern "agent:{parent_id}:{num}".
    try do
      prefix = "agent:#{session_id}:"
      :ets.foldl(
        fn {key, _val}, acc ->
          if is_binary(key) and String.starts_with?(key, prefix) do
            :ets.insert(@cancel_table, {key, true})
            Logger.info("[loop] Cancel propagated to sub-agent #{key}")
          end
          acc
        end,
        :ok,
        @cancel_table
      )
    rescue
      _ -> :ok
    end

    # Also cancel sub-agents that are registered in the SessionRegistry
    # (in case they haven't set a cancel flag yet — e.g., still spawning)
    try do
      prefix = "agent:#{session_id}:"
      Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn key ->
        if is_binary(key) and String.starts_with?(key, prefix) do
          :ets.insert(@cancel_table, {key, true})
          Logger.info("[loop] Cancel propagated to registered sub-agent #{key}")
        end
      end)
    rescue
      _ -> :ok
    end

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
      parent_session_id: Keyword.get(opts, :parent_session_id),
      allowed_tools: Keyword.get(opts, :allowed_tools),
      blocked_tools: Keyword.get(opts, :blocked_tools, []),
      system_prompt_override: Keyword.get(opts, :system_prompt_override),
      working_dir: Keyword.get(opts, :working_dir) || Application.get_env(:optimal_system_agent, :working_dir)
    }

    {strategy_mod, strategy_state} =
      # Strategies module removed — always use nil (no-op strategy)
      {nil, %{}}

    state = %{state | strategy: strategy_mod, strategy_state: strategy_state, started_at: DateTime.utc_now()}

    if restored != %{} do
      Logger.info("[loop] Restored checkpoint for session #{session_id} — iteration=#{iteration}, messages=#{length(messages)}")
    end

    # Vault stripped in onion rebuild — Layer 14 reimplements.

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

    # NoiseFilter DISABLED (Fix #57). Every message hits the LLM.
    # "ok" might mean "proceed", "yes" might mean "deploy it."
    # Small messages are confirmations from human to model — filtering
    # them breaks conversational flow. Signal-aware depth in the system
    # prompt handles response calibration instead.
    _noise_result = :pass

    # Intelligence wiring removed (Intelligence module deleted)

    # 2. Compact message history if needed, then process through agent loop
    compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages) || state.messages
    state = %{state | messages: compacted}

    # Memory nudge every N turns (Phase 6)
    interval = Application.get_env(:optimal_system_agent, :auto_insights_interval, 10)
    message_with_nudge =
      if rem(state.turn_count, interval) == 0 and state.turn_count > 0 do
        message <>
          "\n\n[System: You've had #{state.turn_count} exchanges. " <>
          "Consider saving important context with memory_save if you haven't recently.]"
      else
        message
      end

    # Inject directives before the user message to guide weaker models.
    pre_directives = []

    # Directive 1: Explore-first for complex coding tasks
    pre_directives =
      if Guardrails.complex_coding_task?(message_with_nudge) do
        [%{
          role: "system",
          content:
            "[System: This task involves code changes. MANDATORY explore-first protocol: " <>
              "Call dir_list and file_read to understand the relevant structure BEFORE " <>
              "calling file_write, file_edit, or shell_execute. " <>
              "Never modify a file you haven't read first.]"
        } | pre_directives]
      else
        pre_directives
      end

    # Directive 2: Force delegation for multi-part tasks with role names
    pre_directives =
      if state.permission_tier == :full and Guardrails.delegation_task?(message_with_nudge) do
        [%{
          role: "system",
          content:
            "[System: MANDATORY TEAM DISPATCH. This task has multiple independent " <>
              "deliverables. You MUST assemble a team using the `delegate` tool. " <>
              "Do NOT write files yourself for this task. " <>
              "For EACH bullet point or numbered item, call: " <>
              "delegate(task: \"<full description with file paths>\", role: \"<best role>\") " <>
              "Choose roles from: architect, backend, frontend, tester, debugger, " <>
              "security-auditor, code-reviewer, researcher, devops, doc-writer, refactorer, performance. " <>
              "If no role fits, omit the role parameter. " <>
              "Call delegate IMMEDIATELY — do not call file_write, file_edit, or shell_execute first.]"
        } | pre_directives]
      else
        pre_directives
      end

    messages_to_append = pre_directives ++ [%{role: "user", content: message_with_nudge}]

    state = %{
      state
      | messages: state.messages ++ messages_to_append,
        iteration: 0,
        overflow_retries: 0,
        auto_continues: 0,
        status: :thinking,
        exploration_done: false
    }

    # Auto-explore removed (Explorer module deleted)

    # 2.6. Genre routing — adjust behavior based on signal type when provided by caller.
    # Callers that pre-classify messages pass :signal_genre in opts.
    # Defaults to :direct (current behavior: execute tools immediately).
    signal_genre = Keyword.get(opts, :signal_genre, :direct)

    genre_route = GenreRouter.route_by_genre(signal_genre, message, state)

    case genre_route do
      {:respond, genre_response} ->
        state = %{state | status: :idle}
        Bus.emit(:agent_response, %{session_id: state.session_id, response: genre_response, agent: state.session_id})
        Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
          {:osa_event, %{type: :agent_response, session_id: state.session_id, response: genre_response, response_type: "genre"}})
        {:reply, {:ok, genre_response}, state}

      :execute_tools ->

    # 3. Check if plan mode should trigger
    if not skip_plan and should_plan?(state) do
      # Plan mode: single LLM call with plan overlay, no tools
      state = %{state | plan_mode: true}
      context = Context.build(state)

      Bus.emit(:llm_request, %{session_id: state.session_id, iteration: 0, agent: state.session_id})
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
        usage: usage,
        agent: state.session_id
      })

      case result do
        {:ok, %{content: plan_text}} ->
          plan_input_tokens = Map.get(usage, :input_tokens, 0)
          state = %{state | plan_mode: false, status: :idle}
          state = if plan_input_tokens > 0, do: %{state | last_input_tokens: plan_input_tokens}, else: state
          emit_context_pressure(state)

          Bus.emit(:agent_response, %{
            session_id: state.session_id,
            response: plan_text,
            response_type: "plan",
            agent: state.session_id
          })
          Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
            {:osa_event, %{type: :agent_response, session_id: state.session_id, response: plan_text, response_type: "plan"}})

          {:reply, {:plan, plan_text}, state}

        {:error, reason} ->
          # Fall through to normal execution on plan failure
          Logger.warning(
            "Plan mode LLM call failed (#{inspect(reason)}), falling back to normal execution"
          )

          state = %{state | plan_mode: false}
          {response, state} = run_loop(state)

          response = maybe_scrub_prompt_leak(response)
          response = maybe_strip_dead_phrases(response)

          state = %{
            state
            | messages: state.messages ++ [%{role: "assistant", content: response}],
              status: :idle
          }

          emit_context_pressure(state)

          meta = %{iteration_count: state.iteration, tools_used: extract_tools_used(state.messages)}
          state = %{state | last_meta: meta}

          Bus.emit(:agent_response, %{
            session_id: state.session_id,
            response: response,
            agent: state.session_id
          })

          Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
            {:osa_event, %{type: :agent_response, session_id: state.session_id, response: response, response_type: "direct"}})
          Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
            {:osa_event, %{type: :done, session_id: state.session_id}})

          {:reply, {:ok, response}, state}
      end
    else
      # Normal execution path — message goes straight to LLM
      Logger.info("[loop] Entering run_loop for session #{state.session_id}")
      {response, state} = try do
        run_loop(state)
      rescue
        e ->
          Logger.error("[loop] CRASH in run_loop: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
          {"I hit an error processing that request. Check the logs for details.", state}
      catch
        :exit, reason ->
          Logger.error("[loop] EXIT in run_loop: #{inspect(reason)}")
          {"I hit a timeout or process error. This usually means the LLM connection dropped — try again.", state}
      end

      response = maybe_scrub_prompt_leak(response)
      response = maybe_strip_dead_phrases(response)

      meta = %{iteration_count: state.iteration, tools_used: extract_tools_used(state.messages)}

      state = %{
        state
        | messages: state.messages ++ [%{role: "assistant", content: response}],
          status: :idle,
          last_meta: meta
      }

      emit_context_pressure(state)

      Bus.emit(:agent_response, %{
        session_id: state.session_id,
        response: response,
        agent: state.session_id
      })

      Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
        {:osa_event, %{type: :agent_response, session_id: state.session_id, response: response, response_type: "agent"}})
      Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
        {:osa_event, %{type: :done, session_id: state.session_id}})

      {:reply, {:ok, response}, state}
    end
    end  # closes :execute_tools arm of route_by_genre case
    # (noise_filter end removed — Fix #57, all messages reach LLM)
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
    :ets.insert(:osa_session_provider_overrides, {state.session_id, provider, model})
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

  def handle_call({:set_strategy, _strategy_name}, _from, state) do
    # Strategy module removed — no-op
    {:reply, {:error, :strategies_not_available}, state}
  end

  def handle_call(:get_strategy, _from, state) do
    {:reply, {:ok, :none, %{}}, state}
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
        Logger.warning("Agent loop hit max iterations (#{max_iter}) for session #{sid}")
        tools_used = extract_tools_used(state.messages) |> Enum.join(", ")
        {"I've used all #{max_iter} iterations on this task.\n\n**Tools used:** #{tools_used}\n\nIf the task isn't complete, try breaking it into smaller steps or giving more specific instructions.", state}

      true ->
        do_run_loop(state)
    end
  end

  defp do_run_loop(state) do
    Logger.debug("[loop] do_run_loop entered for #{state.session_id}, iteration=#{state.iteration}")
    # Build context (system prompt + conversation history), using cached system message (Phase 4)
    context = cached_context(state)
    Logger.debug("[loop] context built, #{length(context.messages)} messages")

    # ── Memory injection ─────────────────────────────────────────────
    # Inject relevant memories from long-term store into context.
    # Runs on first iteration only (memories don't change mid-task).
    context =
      if state.iteration == 0 do
        try do
          injected = OptimalSystemAgent.Memory.Synthesis.inject(
            context.messages, state.session_id
          )
          %{context | messages: injected}
        rescue
          e ->
            Logger.debug("[loop] Memory injection skipped: #{inspect(e)}")
            context
        end
      else
        context
      end

    # ── Strategy guidance ────────────────────────────────────────────
    # Consult the active strategy before calling the LLM. The strategy can:
    #   - inject a reasoning guidance message into the context
    #   - signal completion ({:done, ...}) to short-circuit
    #   - request a strategy switch
    # Strategy module removed — pass context through unchanged
    {context, state} = {context, state}

    # Inject iteration awareness — tell the model how many rounds it has left
    max_iter = max_iterations()
    remaining = max_iter - state.iteration
    context = if state.iteration > 0 and remaining <= max_iter do
      budget_msg = %{
        role: "system",
        content: "[Iteration #{state.iteration + 1}/#{max_iter} — #{remaining} remaining. Be efficient. Wrap up if the task is done.]"
      }
      %{context | messages: context.messages ++ [budget_msg]}
    else
      context
    end

    # Emit timing event before LLM call
    Logger.debug("[loop] About to call LLM for #{state.session_id}, iteration #{state.iteration + 1}/#{max_iter}")
    Bus.emit(:llm_request, %{session_id: state.session_id, iteration: state.iteration, agent: state.session_id})
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

    # Computer-use focus mode: if previous iteration used computer_use,
    # slash tools to just computer_use + file_read (avoid 20min Ollama calls)
    last_used_cu = Enum.any?(state.messages, fn msg ->
      msg[:name] == "computer_use" or (is_map(msg[:content]) and msg[:name] == "computer_use")
    end)

    tools_for_call =
      if last_used_cu and state.provider in [:ollama, :lmstudio, :llamacpp] do
        Logger.debug("[loop] Computer-use focus mode — trimming to CU-related tools only")
        Enum.filter(tools_for_call, fn t ->
          t.name in ~w(computer_use file_read ask_user)
        end)
      else
        # Tool budget: local/slow providers choke on 26 tools. Cap at 10 most relevant.
        # Cloud providers (anthropic, openai, google) handle large tool lists fine.
        if state.provider in [:ollama, :lmstudio, :llamacpp] and length(tools_for_call) > 10 do
          Logger.debug("[loop] Trimming tools from #{length(tools_for_call)} to 10 for #{state.provider}")
          {priority, rest} = Enum.split_with(tools_for_call, fn t ->
            t.name in ~w(file_read file_write file_edit shell_execute ask_user computer_use memory_recall)
          end)
          budget = max(10 - length(priority), 0)
          priority ++ Enum.take(rest, budget)
        else
          tools_for_call
        end
      end

    llm_opts = [tools: tools_for_call, temperature: LLMClient.temperature(), max_tokens: max_response_tokens()]
    llm_opts = if thinking_opts, do: Keyword.put(llm_opts, :thinking, thinking_opts), else: llm_opts

    # LLM call — always go through LLMClient which handles all providers
    # (including Ollama Cloud curl fallback with proper tool support)
    result = LLMClient.llm_chat_stream(state, context.messages, llm_opts)

    # Emit timing + usage event after LLM call
    duration_ms = System.monotonic_time(:millisecond) - start_time

    usage =
      case result do
        {:ok, resp} -> Map.get(resp, :usage, %{})
        _ -> %{}
      end

    # Store actual input tokens for accurate context pressure reporting
    # All providers normalise usage to %{input_tokens: n, output_tokens: n}
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
            # CommCoach removed (Intelligence module deleted)
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

        # Append all tool messages in original order
        tool_messages = Enum.map(results, fn {_tc, {tool_msg, _result_str}} -> tool_msg end)
        state = %{state | messages: state.messages ++ tool_messages}

        # Short-circuit: if ALL tool calls were computer_use and ALL succeeded,
        # return the result directly instead of burning another LLM round-trip.
        # This saves 15-60s on slow providers.
        all_computer_use = Enum.all?(tool_calls, fn tc -> tc.name == "computer_use" end)
        all_succeeded = Enum.all?(results, fn {_tc, {_msg, result_str}} ->
          not String.starts_with?(result_str, "Error:")
        end)

        if all_computer_use and all_succeeded do
          summary = results
            |> Enum.map(fn {_tc, {_msg, result_str}} -> result_str end)
            |> Enum.join("\n")
          {summary, state}
        else

        # Checkpoint after tool results — crash recovery can resume from here
        Checkpoint.checkpoint_state(state)

        # Strategy module removed — pass state through unchanged

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

        # Doom loop detection — stop when the same {tool_name}:{error_prefix} signature
        # repeats 3+ consecutive times across iterations, preventing token waste.
        #
        # Per-tool error signatures are built from each individual tool result so
        # partial failures (one tool of several) are still caught.  The list resets
        # completely when any iteration ends with all tools succeeding cleanly.

        error_indicators = ~w(error Error failed not found command not found
                              No such file Permission denied cannot Could not
                              Blocked: invalid syntax unexpected)

        # Collect per-tool failure signatures from this iteration
        iteration_signatures =
          results
          |> Enum.flat_map(fn {tc, {_msg, result_str}} ->
            is_error =
              Enum.any?(error_indicators, fn indicator ->
                String.contains?(result_str, indicator)
              end)

            if is_error do
              # Normalise: first 100 chars, collapse whitespace for stable matching
              error_prefix =
                result_str
                |> String.slice(0, 100)
                |> String.replace(~r/\s+/, " ")
                |> String.trim()

              [{"#{tc.name}:#{error_prefix}", tc.name, error_prefix}]
            else
              []
            end
          end)

        any_clean_success =
          Enum.any?(results, fn {_tc, {_msg, result_str}} ->
            not Enum.any?(error_indicators, fn ind -> String.contains?(result_str, ind) end)
          end)

        # Accumulate failure signatures. Also track tool+file pattern for
        # cases where the error text changes each time but the pattern is
        # "rewrite same file, run it, fail, repeat."
        #
        # When any tool succeeded cleanly this iteration, reset the error-based
        # signatures so a one-off failure doesn't contaminate the next task.
        # File-pattern signatures always accumulate — they catch the "rewrite
        # same file repeatedly" doom loop regardless of success/failure.
        new_sigs =
          if any_clean_success do
            # Drop prior error signatures — clean progress resets the error streak.
            []
          else
            Enum.map(iteration_signatures, fn {sig, _name, _err} -> sig end)
          end

        # PATTERN signatures REMOVED (Fixes #47, #50, #51).
        # The pattern-based detection caused 4+ false positives:
        # - npm test passing 3x → triggered
        # - file_edit on same file 3x (fixing different functions) → triggered
        # - file content containing "error" strings → triggered
        # The error-based detection (iteration_signatures above) is sufficient.
        # It catches the real doom loop: same tool + same error text 3 times.
        file_pattern_sigs = []

        Logger.debug("[doom] Checking #{length(results)} tool results for doom patterns")

        Logger.debug("[doom] Signatures this iteration: #{inspect(Enum.map(iteration_signatures, fn {sig, _, _} -> sig end))}")
        Logger.debug("[doom] Pattern sigs this iteration: #{inspect(file_pattern_sigs)}")
        Logger.debug("[doom] Total accumulated: #{inspect(state.recent_failure_signatures)}")

        updated_failure_signatures =
          (state.recent_failure_signatures ++ new_sigs ++ file_pattern_sigs)
          |> Enum.take(-30)

        state = %{state | recent_failure_signatures: updated_failure_signatures}

        # Find the first signature that has appeared 3+ times
        repeated_signature =
          updated_failure_signatures
          |> Enum.group_by(& &1)
          |> Enum.find(fn {_sig, occurrences} -> length(occurrences) >= 3 end)

        doom_loop? = not is_nil(repeated_signature)

        if doom_loop? do
          {repeated_sig_key, occurrences} = repeated_signature
          repeat_count = length(occurrences)

          # Extract tool name and error text from the signature for the report
          {triggering_tool, triggering_error} =
            case Enum.find(iteration_signatures, fn {sig, _n, _e} -> sig == repeated_sig_key end) do
              {_sig, name, err} -> {name, err}
              nil ->
                # Signature came from a prior iteration — parse from the key
                case String.split(repeated_sig_key, ":", parts: 2) do
                  [name, err] -> {name, err}
                  _ -> {"unknown", repeated_sig_key}
                end
            end

          suggestion =
            cond do
              String.contains?(triggering_error, ["command not found", "not found"]) ->
                "The command or binary does not exist in this environment. " <>
                  "Verify the tool is installed or use an alternative approach."

              String.contains?(triggering_error, ["Permission denied", "cannot", "Could not"]) ->
                "This operation requires elevated permissions or the target path is inaccessible. " <>
                  "Check file permissions or try a different path."

              String.contains?(triggering_error, ["No such file", "No such directory"]) ->
                "The referenced file or directory does not exist. " <>
                  "Confirm the correct path before retrying."

              String.contains?(triggering_error, ["Blocked:"]) ->
                "The tool is blocked by the current permission tier. " <>
                  "Request a permission level change or use an allowed alternative."

              true ->
                "Review the error above, adjust your approach, and try a different strategy " <>
                  "before retrying the same operation."
            end

          doom_message =
            """
            I've hit the same error #{repeat_count} times and I'm stopping to avoid wasting tokens.

            What I tried:
            - #{triggering_tool}: called #{repeat_count} times with the same failing result

            Error pattern:
            - #{triggering_error}

            How to proceed:
            - #{suggestion}
            """
            |> String.trim()

          Logger.warning("[loop] Doom loop detected: #{repeated_sig_key} repeated #{repeat_count} times (session: #{state.session_id})")

          Bus.emit(:system_event, %{
            event: :doom_loop_detected,
            session_id: state.session_id,
            tool_name: triggering_tool,
            error_prefix: triggering_error,
            signature: repeated_sig_key,
            consecutive_failures: repeat_count
          })

          Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
            {:osa_event, %{
              type: :doom_loop_detected,
              session_id: state.session_id,
              tool_name: triggering_tool,
              error_prefix: triggering_error,
              signature: repeated_sig_key,
              consecutive_failures: repeat_count
            }})

          {doom_message, state}
        else
          # Re-prompt
          run_loop(state)
        end

        end  # close computer_use short-circuit else

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

  # Vault stripped in onion rebuild — Layer 14 reimplements.
  defp vault_sleep(_session_id), do: :ok

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
    max_tok = OptimalSystemAgent.Providers.Registry.context_window(state.model)
    # Use actual input_tokens from the last LLM call if available (much more
    # accurate than the word-count heuristic which doesn't count the system
    # prompt or tool definitions).
    estimated = if state.last_input_tokens > 0,
      do: state.last_input_tokens,
      else: OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
    utilization = if max_tok > 0, do: Float.round(estimated / max_tok * 100, 1), else: 0.0
    Logger.info("[ctx] estimated=#{estimated} max=#{max_tok} util=#{utilization}%")

    Bus.emit(:system_event, %{
      event: :context_pressure,
      session_id: state.session_id,
      estimated_tokens: estimated,
      max_tokens: max_tok,
      utilization: utilization
    })

    # Bridge to PubSub for SSE delivery to TUI status bar
    Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
      {:osa_event, %{
        type: :context_pressure,
        session_id: state.session_id,
        estimated_tokens: estimated,
        max_tokens: max_tok,
        utilization: utilization
      }})
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
  defp maybe_update_strategy(state, _message, _opts) do
    # Strategy module removed — no-op
    state
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
