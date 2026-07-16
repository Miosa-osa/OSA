defmodule OptimalSystemAgent.Agent.Loop do
  @moduledoc """
  Bounded ReAct agent loop — the core reasoning engine.

  Messages pass through several pre-LLM gates before the LLM is invoked:

    0. Prompt injection check (Guardrails) — hard block, no memory write
    1. Noise filter — disabled (Fix #57); every message reaches the LLM
    2. Genre routing (GenreRouter) — route by signal genre; some genres
       return a canned response without tool invocation
    3. Plan mode — single LLM call with no tools (when plan_mode is active)
    4. Full ReAct loop — LLM + iterative tool calls

  ## Sub-module responsibilities
  - `Loop.ReactLoop`      — bounded Reason-Act iteration, LLM calls, tool execution
  - `Loop.MessageHandler` — turn-level message decoration (nudges, directives, plan mode)
  - `Loop.ToolFilter`     — tool list budget and weight gating before LLM calls
  - `Loop.DoomLoop`       — repeated-failure detection and halt
  - `Loop.Survey`         — interactive user question / polling
  - `Loop.ToolExecutor`   — permission enforcement, hook pipeline, parallel dispatch
  - `Loop.Guardrails`     — prompt injection detection and behavioral heuristics
  - `Loop.LLMClient`      — provider-agnostic LLM call with streaming
  - `Loop.Checkpoint`     — crash-recovery state snapshots
  - `Loop.GenreRouter`    — signal genre routing
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.GenreRouter
  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Loop.Survey
  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Agent.Hooks

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
    total_tool_calls: 0,
    auto_continues: 0,
    status: :idle,
    tools: [],
    plan_mode: false,
    plan_mode_enabled: false,
    turn_count: 0,
    last_meta: %{iteration_count: 0, tools_used: []},
    explored_files: MapSet.new(),
    exploration_done: false,
    # :full | :workspace | :read_only | :subagent | :auto
    # default stays :full; :auto (near-zero-prompt unattended execution gated by
    # the safety Guardian) is opt-in via /auto_mode or set_permission_mode auto.
    permission_tier: :full,
    # Subagent fields
    parent_session_id: nil,
    allowed_tools: nil,
    blocked_tools: [],
    system_prompt_override: nil,
    # Reasoning strategy — removed, kept for struct compat
    strategy: nil,
    strategy_state: %{},
    # Per-call signal weight (0.0–1.0 or nil)
    signal_weight: nil,
    started_at: nil,
    last_input_tokens: 0,
    # Coordinator mode — restricts tools to delegation/messaging/management only
    coordinator: false,
    # Budget and turn limits — nil = no limit
    max_budget_usd: nil,
    max_turns: nil,
    # Delegation nesting depth — 0 for a top-level session, incremented for
    # each subagent generation. Read by ToolFilter to strip spawning tools at
    # the max depth (fork-bomb / runaway-cost guard).
    delegation_depth: 0
  ]

  @cancel_table :osa_cancel_flags

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

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id, user_id}}
    )
  end

  def process_message(session_id, message, opts \\ []) do
    # The agent loop runs up to `max_turns` iterations with tool calls and
    # subagents, and is bounded logically by max_turns + max_budget_usd — not
    # by wall-clock here. The previous 30s default capped every real task far
    # below the loop's own limits and below the orchestrator's 10-minute
    # Task.await ceiling, so multi-step work (e.g. codebase exploration) died
    # with {:timeout}. Default to that same 10-minute ceiling; callers can
    # still override via opts[:timeout].
    timeout = Keyword.get(opts, :timeout, 600_000)
    GenServer.call(via(session_id), {:process, message, opts}, timeout)
  end

  @doc "Get a snapshot of loop state (iteration count, token estimate, status, etc.)."
  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Get metadata from the last process_message call (iteration_count, tools_used)."
  def get_metadata(session_id) do
    GenServer.call(via(session_id), :get_metadata)
  rescue
    _ -> %{iteration_count: 0, tools_used: []}
  end

  @doc """
  Return the raw message history for a session.

  Used by the Orchestrator to derive real result metadata (commands run,
  final assistant message) from a subagent after it finishes. Safe to call
  from another process — never from inside the loop's own callback.
  """
  @spec get_messages(String.t()) :: [map()]
  def get_messages(session_id) do
    GenServer.call(via(session_id), :get_messages)
  catch
    :exit, _ -> []
  end

  @doc """
  Inject a completed background-agent result into this session's message
  history so the orchestrator LLM can reason about it on its next turn.

  Mirrors Claude Code's completion notification: the result lands in the
  parent's transcript as a synthetic user message. Delivered as a cast so it
  is serialised with the loop's own callbacks and never deadlocks a caller
  that happens to be the loop process itself.
  """
  @spec inject_agent_result(String.t(), String.t()) :: :ok
  def inject_agent_result(session_id, content) when is_binary(content) do
    GenServer.cast(via(session_id), {:inject_agent_result, content})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Compact the live session context buffer.

  Returns `:ok` or `{:error, :no_session}`.
  """
  @spec compact(String.t()) :: :ok | {:error, :no_session | term()}
  def compact(session_id) do
    GenServer.call(via(session_id), :compact)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Proactively compact the live session's context buffer using
  `ProactiveCompaction.compact/1` — folds older turns into a high-recall
  summary before the window fills.

  Returns `{:ok, %{messages_before, messages_after, tokens_before, tokens_after}}`
  or `{:error, :no_session}`.
  """
  @spec proactive_compact(String.t()) :: {:ok, map()} | {:error, :no_session | term()}
  def proactive_compact(session_id) do
    GenServer.call(via(session_id), :proactive_compact, 120_000)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Toggle plan mode for the session.

  Returns `{:ok, enabled?}` or `{:error, :no_session}`.
  """
  @spec toggle_plan_mode(String.t()) :: {:ok, boolean()} | {:error, :no_session | term()}
  def toggle_plan_mode(session_id) do
    GenServer.call(via(session_id), :toggle_plan_mode)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Enable plan mode for the session, saving the current `plan_mode_enabled`
  value so `exit_plan_mode/1` can restore it precisely.

  Returns `{:ok, :entered}`, `{:ok, :already_active}`, or `{:error, :no_session}`.
  """
  @spec enter_plan_mode(String.t()) ::
          {:ok, :entered | :already_active} | {:error, :no_session | term()}
  def enter_plan_mode(session_id) do
    GenServer.call(via(session_id), :enter_plan_mode)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Disable plan mode for the session, restoring the permission state captured
  at `enter_plan_mode/1` time.

  Returns `{:ok, :exited}`, `{:ok, :was_not_active}`, or `{:error, :no_session}`.
  """
  @spec exit_plan_mode(String.t()) ::
          {:ok, :exited | :was_not_active} | {:error, :no_session | term()}
  def exit_plan_mode(session_id) do
    GenServer.call(via(session_id), :exit_plan_mode)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Set the permission tier for a running session
  (`:full | :workspace | :read_only | :subagent | :auto`).

  Used by the HTTP `/commands/execute` auto-mode toggle and the CLI to flip a
  session into near-zero-prompt unattended execution and back to `:full`.
  """
  @spec set_permission_tier(String.t(), atom()) :: {:ok, atom()} | {:error, :no_session}
  def set_permission_tier(session_id, tier) do
    GenServer.call(via(session_id), {:set_permission_tier, tier})
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Cancel a running agent loop for the given session.

  Sets a flag in an ETS table that ReactLoop.run/1 checks at each iteration.
  Concurrent-safe: ETS reads work even while handle_call blocks the mailbox.
  """
  def cancel(session_id) do
    :ets.insert(@cancel_table, {session_id, true})
    Logger.info("[loop] Cancel requested for session #{session_id}")

    prefix = "agent:#{session_id}:"

    try do
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

    try do
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

  @doc """
  Returns the owner (user_id) stored in the SessionRegistry, or `nil`.
  """
  @spec get_owner(String.t()) :: String.t() | nil
  def get_owner(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, owner}] -> owner
      _ -> nil
    end
  end

  @doc """
  Ask the user interactive questions via the TUI survey dialog.
  Delegates to `Loop.Survey.ask/4`.
  """
  @spec ask_user_question(String.t(), String.t(), list(map()), keyword()) ::
          {:ok, term()} | {:skipped} | {:error, :timeout} | {:error, :cancelled}
  defdelegate ask_user_question(session_id, survey_id, questions, opts \\ []),
    to: Survey,
    as: :ask

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    extra_tools = Keyword.get(opts, :extra_tools, [])
    session_id = Keyword.fetch!(opts, :session_id)

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
      tools:
        filter_tools_for_mode(
          Tools.filter_applicable_tools(%{history: []}) ++ extra_tools,
          Keyword.get(opts, :coordinator, false)
        ),
      coordinator: Keyword.get(opts, :coordinator, false),
      max_budget_usd:
        Keyword.get(opts, :max_budget_usd) ||
          Application.get_env(:optimal_system_agent, :max_budget_usd),
      max_turns:
        Keyword.get(opts, :max_turns) || Application.get_env(:optimal_system_agent, :max_turns),
      plan_mode_enabled: Application.get_env(:optimal_system_agent, :plan_mode_enabled, false),
      permission_tier: Keyword.get(opts, :permission_tier, :full),
      delegation_depth: Keyword.get(opts, :delegation_depth, 0),
      parent_session_id: Keyword.get(opts, :parent_session_id),
      allowed_tools: Keyword.get(opts, :allowed_tools),
      blocked_tools: Keyword.get(opts, :blocked_tools, []),
      system_prompt_override: Keyword.get(opts, :system_prompt_override),
      working_dir:
        Keyword.get(opts, :working_dir) ||
          Application.get_env(:optimal_system_agent, :working_dir),
      strategy: nil,
      strategy_state: %{},
      started_at: DateTime.utc_now()
    }

    if restored != %{} do
      Logger.info(
        "[loop] Restored checkpoint for session #{session_id} — iteration=#{iteration}, messages=#{length(messages)}"
      )
    end

    # SessionStart hook — fire-and-forget; announces the new session.
    fire_session_hook(:session_start, %{
      session_id: session_id,
      user_id: state.user_id,
      channel: state.channel,
      resumed: restored != %{}
    })

    {:ok, state}
  end

  @impl true
  def handle_call({:process, message}, from, state) do
    handle_call({:process, message, []}, from, state)
  end

  @impl true
  def handle_call({:process, message, opts}, _from, state) do
    skip_plan = Keyword.get(opts, :skip_plan, false)

    try do
      :ets.delete(@cancel_table, state.session_id)
    rescue
      ArgumentError -> :ok
    end

    state = apply_overrides(state, opts)
    state = %{state | turn_count: state.turn_count + 1}

    # Budget and turn limit guards — check before any processing
    limit_error = check_limits(state)

    if limit_error do
      {:reply, {:error, limit_error}, state}
    else
      # Clear per-message process caches
      Process.delete(:osa_git_info_cache)
      Process.delete(:osa_doom_recovery_count)
      Process.delete(:osa_workspace_overview_cache)
      Process.delete(:osa_system_msg_cache)
      Process.put(:osa_memory_version, 0)

      # -1. UserPromptSubmit hook — can modify or block the message
      {message, state} =
        try do
          case Hooks.run(:user_prompt_submit, %{
                 message: message,
                 session_id: state.session_id,
                 turn_count: state.turn_count
               }) do
            {:ok, %{message: modified}} when is_binary(modified) -> {modified, state}
            {:blocked, _reason} -> {nil, %{state | status: :idle}}
            _ -> {message, state}
          end
        rescue
          _ -> {message, state}
        catch
          :exit, _ -> {message, state}
        end

      if is_nil(message) do
        {:reply, {:error, "Message blocked by hook"}, state}
      else
        # 0. Prompt injection guard
        if Guardrails.prompt_injection?(message) do
          refusal = Guardrails.prompt_extraction_refusal()
          {:reply, {:ok, refusal}, %{state | status: :idle}}
        else
          signal_weight = Keyword.get(opts, :signal_weight, nil)
          state = %{state | signal_weight: signal_weight}

          # Compact message history if needed
          compacted =
            OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages) || state.messages

          state = %{state | messages: compacted}

          # Build decorated message list (nudges + pre-directives + user message)
          messages_to_append = MessageHandler.build_messages(message, state)

          state = %{
            state
            | messages: state.messages ++ messages_to_append,
              iteration: 0,
              overflow_retries: 0,
              auto_continues: 0,
              status: :thinking,
              exploration_done: false,
              # Reset doom loop signatures on each new user turn —
              # the user explicitly wants to try again, don't carry over old failures
              recent_failure_signatures: []
          }

          # Genre routing
          signal_genre = Keyword.get(opts, :signal_genre, :direct)
          genre_route = GenreRouter.route_by_genre(signal_genre, message, state)

          case genre_route do
            {:respond, genre_response} ->
              state = %{state | status: :idle}

              Bus.emit(:agent_response, %{
                session_id: state.session_id,
                response: genre_response,
                agent: state.session_id
              })

              Phoenix.PubSub.broadcast(
                OptimalSystemAgent.PubSub,
                "osa:session:#{state.session_id}",
                {:osa_event,
                 %{
                   type: :agent_response,
                   session_id: state.session_id,
                   response: genre_response,
                   response_type: "genre"
                 }}
              )

              {:reply, {:ok, genre_response}, state}

            :execute_tools ->
              dispatch_message(state, skip_plan)
          end
        end
      end

      # if message not blocked
    end

    # if limit_error
  end

  @impl true
  def handle_call(:get_metadata, _from, state) do
    {:reply, state.last_meta, state}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:get_state, _from, state) do
    uptime = if state.started_at, do: DateTime.diff(DateTime.utc_now(), state.started_at), else: 0

    snap = %{
      session_id: state.session_id,
      iteration: state.iteration,
      tokens_used: Telemetry.estimate_tokens(state),
      tools_called: state.last_meta[:tools_used] || [],
      status: state.status,
      started_at: state.started_at,
      uptime_seconds: uptime,
      provider: state.provider,
      model: state.model
    }

    {:reply, {:ok, snap}, state}
  end

  @impl true
  def handle_call({:swap_provider, provider, model}, _from, state) do
    :ets.insert(:osa_session_provider_overrides, {state.session_id, provider, model})
    {:reply, :ok, %{state | provider: provider, model: model}}
  end

  @impl true
  def handle_call(:toggle_plan_mode, _from, state) do
    # Route the toggle through the exact same transition as enter/exit so the
    # three entry points can never disagree about plan_mode_enabled or the
    # saved pre-entry value. Toggling reports the resulting boolean.
    {_result, new_state} =
      if state.plan_mode_enabled do
        do_exit_plan_mode(state)
      else
        do_enter_plan_mode(state)
      end

    {:reply, {:ok, new_state.plan_mode_enabled}, new_state}
  end

  def handle_call(:compact, _from, state) do
    compacted = OptimalSystemAgent.Agent.Compactor.maybe_compact(state.messages)
    {:reply, :ok, %{state | messages: compacted}}
  end

  def handle_call(:proactive_compact, _from, state) do
    messages = state.messages || []
    compacted = OptimalSystemAgent.Agent.Loop.ProactiveCompaction.compact(messages)

    stats = %{
      messages_before: length(messages),
      messages_after: length(compacted),
      tokens_before: OptimalSystemAgent.Agent.Compactor.estimate_tokens(messages),
      tokens_after: OptimalSystemAgent.Agent.Compactor.estimate_tokens(compacted)
    }

    {:reply, {:ok, stats}, %{state | messages: compacted}}
  end

  def handle_call(:enter_plan_mode, _from, state) do
    {result, new_state} = do_enter_plan_mode(state)
    {:reply, {:ok, result}, new_state}
  end

  def handle_call(:exit_plan_mode, _from, state) do
    {result, new_state} = do_exit_plan_mode(state)
    {:reply, {:ok, result}, new_state}
  end

  def handle_call({:set_permission_tier, tier}, _from, state)
      when tier in [:full, :workspace, :read_only, :auto] do
    {:reply, {:ok, tier}, %{state | permission_tier: tier}}
  end

  def handle_call({:get_permission_tier}, _from, state) do
    {:reply, {:ok, state.permission_tier}, state}
  end

  def handle_call({:set_strategy, _strategy_name}, _from, state) do
    {:reply, {:error, :strategies_not_available}, state}
  end

  def handle_call(:get_strategy, _from, state) do
    {:reply, {:ok, :none, %{}}, state}
  end

  @impl true
  def handle_cast({:inject_agent_result, content}, state) do
    injected = %{role: "user", content: content}
    {:noreply, %{state | messages: state.messages ++ [injected]}}
  end

  @impl true
  def terminate(:normal, state) do
    fire_session_end(state)
    Checkpoint.clear_checkpoint(state.session_id)
    :ok
  end

  def terminate(:shutdown, state) do
    fire_session_end(state)
    Checkpoint.clear_checkpoint(state.session_id)
    :ok
  end

  def terminate({:shutdown, _}, state) do
    fire_session_end(state)
    Checkpoint.clear_checkpoint(state.session_id)
    :ok
  end

  def terminate(reason, state) do
    fire_session_end(state, reason)
    :ok
  end

  # SessionEnd hook — run synchronously so session-cleanup handlers execute
  # before the process exits. Fully guarded: hook problems never block shutdown.
  defp fire_session_end(state, reason \\ :normal)

  defp fire_session_end(%{session_id: sid} = state, reason) when is_binary(sid) do
    try do
      Hooks.run(:session_end, %{
        session_id: sid,
        user_id: Map.get(state, :user_id),
        channel: Map.get(state, :channel),
        reason: reason,
        turn_count: Map.get(state, :turn_count, 0)
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp fire_session_end(_state, _reason), do: :ok

  # SessionStart hook helper — never blocks or crashes loop init.
  defp fire_session_hook(event, payload) do
    Hooks.run_async(event, payload)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # --- Message Dispatch ---

  defp dispatch_message(state, skip_plan) do
    if not skip_plan and should_plan?(state) do
      state = %{state | plan_mode: true}

      case MessageHandler.run_plan_mode(state) do
        {:ok, plan_text, state} ->
          state = %{state | status: :idle}
          Telemetry.emit_context_pressure(state)

          Phoenix.PubSub.broadcast(
            OptimalSystemAgent.PubSub,
            "osa:session:#{state.session_id}",
            {:osa_event, %{type: :done, session_id: state.session_id}}
          )

          {:reply, {:plan, plan_text}, state}

        {:error, _reason, state} ->
          run_and_reply(state)
      end
    else
      run_and_reply(state)
    end
  end

  defp run_and_reply(state) do
    Logger.info("[loop] Entering ReactLoop for session #{state.session_id}")

    {response, state} =
      try do
        ReactLoop.run(state)
      rescue
        e ->
          Logger.error(
            "[loop] CRASH in ReactLoop: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {"I hit an error processing that request. Check the logs for details.", state}
      catch
        :exit, reason ->
          Logger.error("[loop] EXIT in ReactLoop: #{inspect(reason)}")

          {"I hit a timeout or process error. This usually means the LLM connection dropped — try again.",
           state}
      end

    response = maybe_scrub_prompt_leak(response)
    response = maybe_strip_dead_phrases(response)

    meta = %{
      iteration_count: state.iteration,
      tools_used: Telemetry.extract_tools_used(state.messages)
    }

    state = %{
      state
      | messages: state.messages ++ [%{role: "assistant", content: response}],
        status: :idle,
        last_meta: meta
    }

    Telemetry.emit_context_pressure(state)

    Bus.emit(:agent_response, %{
      session_id: state.session_id,
      response: response,
      agent: state.session_id
    })

    # Fire post_response hooks (async, non-blocking)
    try do
      Hooks.run_async(:post_response, %{
        session_id: state.session_id,
        response: response,
        input: List.last(state.messages) |> Map.get(:content, ""),
        turn_count: state.turn_count,
        iteration: state.iteration,
        tools_used: Map.get(state.last_meta, :tools_used, []),
        total_tool_calls: state.total_tool_calls
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :agent_response,
         session_id: state.session_id,
         response: response,
         response_type: "agent"
       }}
    )

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event, %{type: :done, session_id: state.session_id}}
    )

    {:reply, {:ok, response}, state}
  end

  # --- Output Guardrails ---

  defp maybe_scrub_prompt_leak(response) do
    if Guardrails.response_contains_prompt_leak?(response) do
      Logger.warning(
        "[loop] Output guardrail: LLM response contained system prompt content — replacing with refusal"
      )

      Guardrails.prompt_extraction_refusal()
    else
      response
    end
  end

  defp maybe_strip_dead_phrases(response) when is_binary(response) do
    if Guardrails.contains_dead_phrase?(response) do
      Logger.info("[loop] Output guardrail: stripping dead phrases from response")
      Guardrails.strip_dead_phrases(response)
    else
      response
    end
  end

  defp maybe_strip_dead_phrases(response), do: response

  # --- Helpers ---

  defp via(session_id), do: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}}

  defp should_plan?(state), do: state.plan_mode_enabled and not state.plan_mode

  # Single source of truth for the plan-mode state transition, shared by
  # :enter_plan_mode, :exit_plan_mode, and :toggle_plan_mode. Returns
  # `{result, new_state}`.
  defp do_enter_plan_mode(%{plan_mode_enabled: true} = state) do
    # Already active — idempotent; leave the saved pre-entry value untouched.
    {:already_active, state}
  end

  defp do_enter_plan_mode(state) do
    new_state = %{
      state
      | plan_mode_enabled: true,
        # Capture the pre-entry value so exit can restore it precisely.
        strategy_state:
          Map.put(state.strategy_state, :plan_mode_pre_entry, state.plan_mode_enabled)
    }

    {:entered, new_state}
  end

  defp do_exit_plan_mode(%{plan_mode_enabled: false} = state) do
    {:was_not_active, state}
  end

  defp do_exit_plan_mode(state) do
    pre_entry = Map.get(state.strategy_state, :plan_mode_pre_entry, false)

    new_state = %{
      state
      | plan_mode_enabled: pre_entry,
        strategy_state: Map.delete(state.strategy_state, :plan_mode_pre_entry)
    }

    {:exited, new_state}
  end

  defp apply_overrides(state, opts) do
    state
    |> maybe_override(:provider, Keyword.get(opts, :provider))
    |> maybe_override(:model, Keyword.get(opts, :model))
    |> maybe_override(:working_dir, Keyword.get(opts, :working_dir))
  end

  defp maybe_override(state, _key, nil), do: state
  defp maybe_override(state, key, value), do: Map.put(state, key, value)

  # --- Backward-compatible delegations ---

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

  # Check budget and turn limits. Returns nil if OK, or an error string.
  defp check_limits(state) do
    # Budget check
    budget_error =
      if state.max_budget_usd do
        try do
          budget = OptimalSystemAgent.Budget.get_status()
          current_cost = (budget[:total_cost_usd] || 0) / 1

          if current_cost >= state.max_budget_usd do
            Bus.emit(:system_event, %{
              event: :budget_limit_reached,
              session_id: state.session_id,
              current_cost: current_cost,
              limit: state.max_budget_usd
            })

            "Budget limit reached ($#{Float.round(current_cost, 4)} / $#{state.max_budget_usd})"
          end
        rescue
          _ -> nil
        end
      end

    # Turn check
    turn_error =
      if state.max_turns && state.turn_count > state.max_turns do
        Bus.emit(:system_event, %{
          event: :turn_limit_reached,
          session_id: state.session_id,
          turn_count: state.turn_count,
          limit: state.max_turns
        })

        "Turn limit reached (#{state.turn_count}/#{state.max_turns})"
      end

    budget_error || turn_error
  end

  # Coordinator mode restricts tools to delegation, messaging, and management
  @coordinator_tools ~w(delegate send_message tool_search memory_recall memory_save
    task_write list_agents list_skills session_search ask_user)
  defp filter_tools_for_mode(tools, false), do: tools

  defp filter_tools_for_mode(tools, true) do
    Enum.filter(tools, fn tool ->
      name = tool[:name] || tool.name
      name in @coordinator_tools
    end)
  end
end
