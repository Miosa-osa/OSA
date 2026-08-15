defmodule OptimalSystemAgent.Agent.Loop.TurnPipeline do
  @moduledoc """
  Ordered pre-LLM gate pipeline for a single agent turn.

  Extracted from the `Loop` GenServer's `{:process, message, opts}` callback so
  the per-turn gates live in one place with named steps instead of one
  ~115-line god-callback. Runs, in order:

    1. `clear_cancel_flag`     — drop any stale cancel flag for this session
    2. `apply_overrides`       — per-call provider/model/working_dir overrides
    3. increment turn_count
    4. `Limits.check`          — budget / turn-limit guard (hard stop)
    5. `clear_message_caches`  — reset per-message process-dictionary caches
    6. `run_user_prompt_submit_hook` — UserPromptSubmit hook (may rewrite/block)
    7. prompt-injection guard  — `Guardrails` hard block (no memory write)
    8. `prepare_turn`          — signal weight, compaction, message build, reset
    9. `route_genre`           — `GenreRouter`; canned response or tool execution

  Returns either `{:reply, reply, state}` for a terminal gate outcome, or
  `{:dispatch, state, skip_plan}` to hand control back to `Loop` for plan-mode /
  ReactLoop execution. Behaviour is identical to the original inline callback.
  """
  require Logger

  alias OptimalSystemAgent.Agent.ContextEngine.Router, as: ContextEngine
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Observability
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.TurnTermination
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.ContextWindow
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.GenreRouter
  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Agent.Loop.Limits
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Store.SessionTranscript

  @doc """
  Run the pre-LLM gate pipeline for one turn.

  Returns `{:reply, reply, state}` for a terminal outcome (limit breach, hook
  block, prompt-injection refusal, or genre canned response) or
  `{:dispatch, state, skip_plan}` when the turn should proceed to tool
  execution in `Loop`.
  """
  @spec run(term(), keyword(), map()) ::
          {:reply, term(), map()} | {:dispatch, map(), boolean()}
  def run(message, opts, state) do
    skip_plan = Keyword.get(opts, :skip_plan, false)

    # A fresh turn — release the previous turn's terminal-frame claim, so this
    # turn's own terminal frame can be sent exactly once.
    TurnTermination.open(state.session_id)

    clear_cancel_flag(state)

    state = apply_overrides(state, opts)
    state = %{state | turn_count: state.turn_count + 1}

    # Budget and turn limit guards — check before any processing
    limit_error = Limits.check(state)

    if limit_error do
      # Broadcast a terminal session event so async clients (Rust TUI / SSE) stop
      # 'Processing…' immediately with the real cap message instead of spinning
      # for the full request timeout and false-reporting a timeout.
      broadcast_terminal(state, limit_error)
      {:reply, {:error, limit_error}, state}
    else
      # Clear per-message process caches
      clear_message_caches()

      # -1. UserPromptSubmit hook — can modify or block the message.
      # CC parity: a block is VISIBLE (the hook's reason is shown to the
      # user) and exit-0 stdout / additionalContext is injected into the turn.
      {message, hook_context, block_reason, state} =
        run_user_prompt_submit_hook(message, state)

      if is_nil(message) do
        reason = "Prompt blocked by hook: #{block_reason || "no reason given"}"
        broadcast_terminal(state, reason)
        {:reply, {:error, reason}, state}
      else
        # 0. Prompt injection guard
        if Guardrails.prompt_injection?(message) do
          refusal = Guardrails.prompt_extraction_refusal()
          state = %{state | status: :idle}
          broadcast_terminal(state, refusal)
          {:reply, {:ok, refusal}, state}
        else
          state = prepare_turn(message, opts, state)
          state = inject_hook_context(state, hook_context)
          route_genre(message, opts, state, skip_plan)
        end
      end
    end
  end

  # --- Steps ---

  # Mirror the terminal broadcast that run_and_reply performs on the normal
  # path, so async clients render the message and leave the Processing state
  # promptly instead of waiting out the full request timeout.
  defp broadcast_terminal(state, text) do
    # Claimed, not merely sent: the orchestrate route terminates the same
    # `{:error, reason}` a second time, and a duplicate `done` drives the TUI's
    # queue drain into a live turn.
    if TurnTermination.claim(state.session_id) do
      do_broadcast_terminal(state, text)
    else
      :ok
    end
  end

  defp do_broadcast_terminal(state, text) do
    topic = "osa:session:#{state.session_id}"

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      topic,
      {:osa_event,
       %{
         type: :agent_response,
         session_id: state.session_id,
         message_id: LLMClient.current_message_id(),
         response: text,
         response_type: "agent"
       }}
    )

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      topic,
      {:osa_event, %{type: :done, session_id: state.session_id}}
    )

    :ok
  rescue
    _ -> :ok
  end

  # A finished turn clears the cancel flag for this session AND every
  # descendant it may have spawned. `Loop.cancel/1` flags a whole subtree; a
  # single-key delete here left every descendant flag behind forever (they are
  # force-terminated by cancel and so never reach their own delete), which grows
  # `:osa_cancel_flags` unboundedly and makes a later run under a reused agent
  # id read as "already cancelled". Set and clear must cover the same set.
  defp clear_cancel_flag(state) do
    OptimalSystemAgent.Agent.Loop.clear_cancel(state.session_id)
  rescue
    _ -> :ok
  end

  defp apply_overrides(state, opts) do
    state =
      state
      |> maybe_override(:provider, Keyword.get(opts, :provider))
      |> maybe_override(:model, Keyword.get(opts, :model))
      |> maybe_override(:working_dir, Keyword.get(opts, :working_dir))

    # Publish the resolved working_dir into the process dictionary so every
    # cwd lookup within this turn (running in the Loop process) resolves via
    # Cwd.get() to the session's dir — mechanism for "live Loop state" in the
    # Cwd resolution order — never the backend's boot dir.
    OptimalSystemAgent.Workspace.Cwd.put_process_override(Map.get(state, :working_dir))

    # …and into the session→workspace table, which is NOT process-local. The
    # process dictionary above only reaches code running in this process; the
    # permission scope check runs inside a spawned tool Task. See
    # `Workspace.Cwd`'s resolution order.
    OptimalSystemAgent.Workspace.Cwd.put_session_dir(
      Map.get(state, :session_id),
      Map.get(state, :working_dir)
    )

    # Same mechanism, for session identity: publish which session this process
    # is acting for so `Settings.current_session/0` can scope the session
    # settings layer (and so skill-touch / diagnostics lookups that already read
    # :osa_session_id resolve on the loop process too). Without this the
    # "session" layer is one daemon-wide namespace shared by every session.
    case Map.get(state, :session_id) do
      sid when is_binary(sid) and sid != "" -> Process.put(:osa_session_id, sid)
      _ -> :ok
    end

    state
  end

  defp maybe_override(state, _key, nil), do: state
  defp maybe_override(state, key, value), do: Map.put(state, key, value)

  defp clear_message_caches do
    Process.delete(:osa_git_info_cache)
    Process.delete(:osa_workspace_overview_cache)
    Process.delete(:osa_system_msg_cache)
    Process.put(:osa_memory_version, 0)
  end

  # Returns {message | nil, injected_context, block_reason | nil, state}.
  defp run_user_prompt_submit_hook(message, state) do
    try do
      case Hooks.run(:user_prompt_submit, %{
             message: message,
             session_id: state.session_id,
             turn_count: state.turn_count,
             working_dir: Map.get(state, :working_dir)
           }) do
        {:ok, %{message: modified} = final} when is_binary(modified) ->
          {modified, Map.get(final, :injected_context, []), nil, state}

        {:blocked, reason} ->
          {nil, [], reason, %{state | status: :idle}}

        _ ->
          {message, [], nil, state}
      end
    rescue
      _ -> {message, [], nil, state}
    catch
      :exit, _ -> {message, [], nil, state}
    end
  end

  # Append UserPromptSubmit hook context (CC additionalContext / exit-0
  # stdout) as a system message so the model sees it within this turn.
  defp inject_hook_context(state, []), do: state

  defp inject_hook_context(state, context) when is_list(context) do
    text = context |> Enum.map(&to_string/1) |> Enum.join("\n") |> String.trim()

    if text == "" do
      state
    else
      msg = %{
        role: "system",
        content: "<user-prompt-submit-hook>\n#{text}\n</user-prompt-submit-hook>"
      }

      %{state | messages: state.messages ++ [msg]}
    end
  end

  defp inject_hook_context(state, _), do: state

  # signal weight, compaction, decorated message build, and per-turn state reset
  defp prepare_turn(message, opts, state) do
    # Persist the USER turn at ingestion (store-at-source, the Claude Code /
    # OpenCode pattern): the raw prompt is committed under its own role
    # before nudge/directive decoration and before the plan/genre branches,
    # so cancelled turns, ReactLoop crashes, and plan-mode turns still
    # record what the user asked. The post_response hook persists only the
    # assistant side (see Hooks.Handlers.save_transcript/1).
    persist_user_turn(state.session_id, message)

    # Drop the previous turn's assistant-message id. A turn that never reaches
    # an LLM call (genre reply, early error frame) would otherwise finalize
    # carrying the LAST turn's id, which the client reads as a repeat of an
    # already-finalized message and discards.
    LLMClient.reset_message_id()

    signal_weight = Keyword.get(opts, :signal_weight, nil)

    # Mint a per-turn correlation id (prompt.id-style) and emit turn_start so the
    # per-session event stream is correlated + replayable (primitive #30).
    state = %{state | signal_weight: signal_weight, turn_id: Observability.new_turn_id()}
    Observability.turn_start(state)

    # Compact message history if needed, then refresh the token-count signal
    # so a second compactor later in the SAME iteration doesn't redo the work
    # off a stale count (finding #8).
    state = compact_and_refresh_tokens(state)

    # Build decorated message list (nudges + pre-directives + user message).
    # Thread any pasted/attached images so vision requests reach the model as
    # image content blocks rather than a dead "[Image #N]" text reference.
    #
    # `:image_source` is the trust marker for those paths. It is `:user` only
    # when the caller asserted an explicit user action (drag-and-drop, paste,
    # `@file`); absent/unknown means `:model` and keeps full allowed-roots
    # confinement. See `MessageHandler.build_messages/4`.
    images = Keyword.get(opts, :images, [])
    image_source = Keyword.get(opts, :image_source, :model)
    messages_to_append = MessageHandler.build_messages(message, state, images, image_source)

    %{state | messages: state.messages ++ messages_to_append, current_input: message}
    |> reset_per_turn_fields()
  end

  # Run `Compactor.maybe_compact/4` against `state.messages` and, when it
  # actually shrank history, immediately refresh `:last_input_tokens` to
  # match.
  #
  # `last_input_tokens` is otherwise only written by `Loop.Accounting` AFTER
  # a provider round-trip. Left stale, `ReactLoop.do_iteration/1`'s own
  # `ProactiveCompaction.should_compact?/2` check — which runs later in the
  # SAME iteration (iteration 0 of a turn) and reads the same field — sees
  # the identical pre-compaction count and fires a SECOND LLM summarization
  # round-trip back to back with this one (finding #8). Re-estimating here
  # from the now-shrunk history lets that second check correctly skip.
  #
  # Public (not `defp`) + `@doc false` so this dedup is directly
  # unit-testable.
  @doc false
  @spec compact_and_refresh_tokens(map()) :: map()
  def compact_and_refresh_tokens(state) do
    original_messages = state.messages

    compacted =
      bounded_compaction(original_messages, fn ->
        Compactor.maybe_compact(
          original_messages,
          Map.get(state, :last_input_tokens, 0),
          state.session_id,
          # Real per-model window (`effective_context_window_info/2`). Without
          # this the compactor budgeted every model against a flat 128k and
          # summarized 1M-window sessions at ~11% occupancy on every turn.
          context_window: ContextWindow.resolve(state)
        )
      end) || original_messages

    state =
      if compacted != original_messages do
        %{state | last_input_tokens: ContextEngine.estimate_tokens(compacted)}
      else
        state
      end

    # Compaction's own summarizer round-trips run in the task above, which holds
    # no loop state; they staged their priced usage into `Accounting`'s side
    # ledger. This is the first point after that task returns where we hold both
    # the state and the session id, so bill them here. A no-op when nothing was
    # staged (deterministic compaction, no-op compaction, LLM disabled).
    state = Accounting.absorb_side_spend(state)

    %{state | messages: compacted}
  end

  @doc """
  Run a compaction closure under a wall-clock bound, falling back to the
  DETERMINISTIC compaction path when it expires.

  Compaction is the one call an unattended agent cannot skip: history has
  outgrown the window, so the turn cannot proceed until it shrinks. The
  summarizer inside `Compactor` reaches a provider (`Providers.chat/2`) with no
  timeout of its own, and neither `Compactor` nor `ProactiveCompaction`
  contained the string `timeout` anywhere — so a provider that accepted the
  connection and then went quiet stalled the whole loop indefinitely, with no
  turn boundary, no event, and nothing for a watchdog to observe.

  The closure runs in a supervised task; on expiry the task is killed
  (`Task.shutdown(:brutal_kill)` — a summarizer stuck in a socket read will not
  honour a graceful shutdown) and we fall back to `Compactor.micro_compact/1`,
  which is pure/deterministic and reaches no provider. That still shrinks
  history, so the turn makes progress instead of hanging.

  Bound is `:compaction_timeout_ms` (default 120s — the summarizer is a real
  generation, so this is generous; it is a wedge detector, not a latency SLA).

  Public + `@doc false` so `Loop` can share the same bound for its `/compact`
  and `/proactive-compact` call sites without duplicating the policy.
  """
  @spec bounded_compaction([map()], (-> [map()] | nil)) :: [map()] | nil
  def bounded_compaction(fallback_messages, fun) when is_function(fun, 0) do
    timeout =
      Application.get_env(:optimal_system_agent, :compaction_timeout_ms, 120_000)

    task = Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.error("[turn] compaction crashed: #{inspect(reason)} — deterministic fallback")
        deterministic_compaction(fallback_messages)

      nil ->
        Logger.error(
          "[turn] compaction exceeded #{timeout}ms (wedged summarizer) — " <>
            "killed it and fell back to deterministic micro-compaction"
        )

        deterministic_compaction(fallback_messages)
    end
  rescue
    # No TaskSupervisor (bare unit test, stripped release) — degrade to running
    # inline rather than failing the turn. Unbounded, but strictly better than
    # crashing, and the supervisor is present in every real runtime.
    _ -> fun.()
  end

  defp deterministic_compaction(messages) do
    Compactor.micro_compact(messages)
  rescue
    _ -> messages
  end

  @doc """
  Zero out every counter/flag that is per-turn in intent so it cannot leak
  from one user turn into the next.

  Split out from `prepare_turn/3` as its own function so the reset list is
  independently testable — the fields below have historically been added to
  the loop without a matching entry here, causing state to silently bleed
  across turns (cross-turn doom-loop false halts, a self-disabling goal
  verifier, leaked token-target continues). When adding a new per-turn
  counter anywhere in the loop, add its reset here too.
  """
  @spec reset_per_turn_fields(map()) :: map()
  def reset_per_turn_fields(state) do
    state = %{
      state
      | iteration: 0,
        overflow_retries: 0,
        auto_continues: 0,
        status: :thinking,
        exploration_done: false,
        # Reset doom loop signatures on each new user turn —
        # the user explicitly wants to try again, don't carry over old failures
        recent_failure_signatures: [],
        # Reset repeated-failure recovery attempts each new user turn (formerly
        # a per-message process-dict delete in clear_message_caches).
        doom_recovery_count: 0
    }

    # `Map.merge/2`, NOT the `%{state | ...}` struct-update syntax, for these
    # four: they are lazily `Map.put` onto the loop state the first time
    # each feature actually runs (goal_verifier.ex, doom_loop/reasoning_only.ex,
    # react_loop.ex's token-target nudge) rather than being declared
    # `Loop` defstruct fields with a default. A turn that never exercised one
    # of these features yet genuinely does not have the key on its state map,
    # and `%{state | key: val}` raises `KeyError`/`BadKeyError` for a key that
    # isn't already present — `Map.merge/2` sets it either way.
    Map.merge(state, %{
      # Clear the terminal-source mark each new user turn. This is what makes
      # `TerminalSource`'s opt-in marking safe: without it, one guard halt would
      # make every later turn in the session render as a system message instead
      # of as the model's answer. A fresh user message is a fresh turn with a
      # fresh author.
      terminal_source: nil,
      # Reset the reasoning-only doom-loop streak each new user turn — a
      # turn that ended with 1-2 trailing empty/reasoning-only generations
      # must not carry that streak into the NEXT turn's threshold check
      # (false "reasoning-only spin" halt on a fresh turn's first empty
      # generation). See doom_loop/reasoning_only.ex.
      reasoning_only_streak: 0,
      # Reset goal-verifier per-turn counters each new user turn. Both are
      # gated against per-session maxes (goal_verifier.ex `max_runs/0`,
      # `stall_threshold/0`); leaving them un-reset self-disables the
      # verifier for every subsequent turn in the session once turn 1
      # exhausts its runs.
      goal_verifier_runs: 0,
      goal_verifier_stall_count: 0,
      # Blocker streak + auto-pause latch (goal_verifier.ex triage gate). Fresh
      # user input is a fresh chance: the user has now seen the "I'm blocked on
      # X" handoff and may well have cleared X, so a new turn must not start
      # already paused, nor 2/3 of the way into a stale blocker streak.
      goal_verifier_blocker_key: nil,
      goal_verifier_blocker_streak: 0,
      goal_verifier_paused: false,
      # Reset the token-target "work to target" continue counter each new
      # user turn — otherwise it leaks across turns and the feature dies
      # after the first turn that used it up.
      target_continues: 0,
      # Reset the grounded-verification gate's re-prompt budget each new user
      # turn. `VerificationGate` documents and only makes sense with a PER-TURN
      # cap (`@max_reprompts`, so a stubborn model can't trap one turn's
      # completion path), but the counter lives on the long-lived Loop state and
      # nothing reset it — so two gate firings anywhere in a session disabled
      # the gate permanently, silently, on exactly the long sessions it exists
      # for. Written by `VerificationGate.build_directive/1` via `Map.put`.
      verification_gate_prompts: 0,
      # Clause 0 (`:unobserved_background`) spends a SEPARATE budget from the
      # ledger clauses — see `VerificationGate.@max_background_reprompts`. It
      # needs the same per-turn reset for the same reason.
      background_gate_prompts: 0,
      # One-per-turn budget for the announcement backstop in `ReactLoop`
      # (`docs/research/failure-taxonomy.md` §7): a turn that ends on "let me
      # write it now" gets exactly one chance to actually write it.
      announcement_continues: 0
    })
  end

  @doc """
  Persist the raw user prompt to the transcript store at ingestion time.

  Best-effort: transcript loss must never fail the turn (`save_turn/4`
  already rescues internally; this wrapper adds belt-and-braces). Also runs
  memory auto-extraction on the REAL user text — previously the
  post_response handler mined the assistant's reply by mistake because its
  :input field was mis-derived.
  """
  @spec persist_user_turn(String.t(), term()) :: :ok
  def persist_user_turn(session_id, message) when is_binary(message) and message != "" do
    SessionTranscript.save_turn(session_id, "user", message)

    # Title the session from its opening message, synchronously and without a
    # network call, so it is never listed as a bare id — an untitled row in a
    # picker is useless exactly when you are scanning for the one you want.
    # A no-op after the first turn. The LLM refinement it schedules is
    # fire-and-forget: titling cannot block, slow, or fail this turn.
    OptimalSystemAgent.Memory.SessionTitler.ensure_title(session_id, message)

    Task.start(fn ->
      try do
        extractions = OptimalSystemAgent.Memory.AutoExtract.extract(message)

        if extractions != [] do
          OptimalSystemAgent.Memory.AutoExtract.save_extracted(extractions, session_id)
        end
      rescue
        _ -> :ok
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  def persist_user_turn(_session_id, _message), do: :ok

  defp route_genre(message, opts, state, skip_plan) do
    # Genre routing
    signal_genre = Keyword.get(opts, :signal_genre, :direct)
    genre_route = GenreRouter.route_by_genre(signal_genre, message, state)

    case genre_route do
      {:respond, genre_response} ->
        state = %{state | status: :idle}

        # Genre turns bypass run_and_reply/:post_response — persist the
        # canned reply so the ingestion-time user turn doesn't sit
        # unanswered in the transcript used by /sessions resume and recap.
        SessionTranscript.save_turn(state.session_id, "assistant", genre_response,
          tool_name: "genre"
        )

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
        {:dispatch, state, skip_plan}
    end
  end
end
