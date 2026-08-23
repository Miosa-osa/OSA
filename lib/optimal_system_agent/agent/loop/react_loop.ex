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
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.StreamingToolExecutor
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Observability

  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.ToolDiscovery
  alias OptimalSystemAgent.Agent.Loop.ToolError
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Agent.Loop.ToolOrchestrator
  alias OptimalSystemAgent.Agent.Loop.DoomLoop
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Resample
  alias OptimalSystemAgent.Agent.Loop.TerminalSource
  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.Limits
  alias OptimalSystemAgent.Agent.Loop.VerificationGate
  alias OptimalSystemAgent.Agent.Loop.GoalVerifier
  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction
  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.FastPath
  alias OptimalSystemAgent.Providers.StopReason

  @cancel_table :osa_cancel_flags

  # Max auto-continues when a token-budget output target is set (token_target_unmet?/1).
  @max_target_continues 5

  # Bound on the zero-successful-tools verification gate (`needs_verification_gate?/1`).
  #
  # That predicate reads iteration count, task context and "no tool has
  # succeeded" — none of which the gate's own nudge changes. Firing it therefore
  # did not make it stop firing, and unlike every other continuation clause it
  # carried no counter: it re-fired on every subsequent text-only answer, and
  # because it RESET `auto_continues` to 2 while the code-in-text clause accepts
  # anything under 3, the two ping-ponged (gate → 2, code-in-text → 3, gate → 2,
  # …) until the global iteration cap. Measured at exactly `max_iterations + 1`
  # round-trips for a single text-only answer — 101 at the default effort.
  @max_zero_tool_gate_prompts 1

  # Bound on the announcement backstop (see the clause in `handle_result/3` for
  # the full note). One: the defect is a turn that ended one step early, and one
  # step is what it gives back.
  @max_announcement_continues 1

  # Should a text-only answer (visible content, no tool calls) be nudged back
  # into the loop on the strength of how its PROSE reads?
  #
  # Default **false**, which makes a text-only answer end the turn — the same
  # thing Codex, grok-build and Claude Code do. When the model returns visible
  # text and calls no tools, that text IS the answer; it has already streamed to
  # the user (`LLMClient.llm_chat_stream` broadcasts every `:text_delta` live),
  # so a continuation cannot un-present it, it can only bolt a second ending
  # onto the turn at the price of a full-context round-trip.
  #
  # The three clauses this gates all key on wording rather than on anything the
  # model actually did:
  #
  #   * `Guardrails.wants_to_continue?/1` — "Let me check…" / "I'll look at…".
  #     A perfectly ordinary sentence in an explanatory answer.
  #   * `Guardrails.code_in_text?/1` — a fenced block of 5+ lines. Also the
  #     correct answer to "show me what this function looks like".
  #   * `Guardrails.needs_verification_gate?/1` — any action verb anywhere in
  #     the user's message plus no successful tool. Fires on "check how the
  #     retry budget is configured and explain it to me", which is answerable
  #     in prose and needs no tool at all.
  #
  # Continuation that keys on something REAL is unaffected and stays on:
  # a genuinely empty generation (the reasoning-only backstop below), pending
  # unverified writes from tools that actually ran (`VerificationGate`), an
  # explicit output-token target, a just-crossed compaction boundary, and stop
  # hooks / goal tracking forcing continuation from `finish_turn/2`.
  #
  # Opt back in for a weak local model that narrates instead of acting:
  #   config :optimal_system_agent, :continue_on_text_only, true
  # or per-session by setting `:continue_on_text_only` on the loop state.
  defp prose_continue?(state) do
    case Map.get(state, :continue_on_text_only) do
      flag when is_boolean(flag) ->
        flag

      _ ->
        Application.get_env(:optimal_system_agent, :continue_on_text_only, false) == true
    end
  end

  # Unlimited unless an operator asks for a limit.
  #
  # Effort governs how hard the model thinks per step - thinking budget,
  # response ceiling, temperature. It has no business governing how LONG a task
  # may take. Tying the two together meant an autonomous run was halted for
  # being long rather than for being wrong: the same task, at the same quality,
  # succeeded or failed purely on which effort tier happened to be selected.
  #
  # For a proactive agent that is expected to work unattended for hours, an
  # iteration count is a clock that eventually fires on healthy work. Runaway is
  # a SHAPE - repeating the same call, making no progress, failing the same way -
  # and the DoomLoop detectors read that shape directly, in seconds, regardless
  # of how many iterations have elapsed. Those are the stop condition. This is
  # not.
  #
  # `config :optimal_system_agent, :max_iterations, <int>` still imposes one for
  # callers that want a bounded run (single-shot CI jobs, evals, sandboxes).
  #
  # The default is a very large finite number rather than `:infinity`. Codex,
  # for reference, ships no iteration, turn or step limit at all - its config
  # surface is model, approval policy, sandbox mode and reasoning effort, and
  # the loop simply runs until the model stops. A finite ceiling keeps the value
  # printable, comparable and assertable, and still stops a true runaway
  # eventually instead of burning forever; at a brisk 30 iterations a minute
  # this is roughly 23 days of continuous work, so nothing real reaches it.
  @unbounded_iterations 1_000_000

  defp max_iterations do
    Application.get_env(:optimal_system_agent, :max_iterations) || @unbounded_iterations
  end

  # Explicit rather than leaning on Elixir term ordering, under which
  # `5 >= :infinity` happens to be false. That is true but accidental, and a
  # reader should not have to know it to be sure the loop cannot stop early.
  defp iteration_cap_reached?(_iter, :infinity), do: false
  defp iteration_cap_reached?(iter, max) when is_integer(max), do: iter >= max
  defp iteration_cap_reached?(_iter, _max), do: false

  defp max_response_tokens do
    # Check for bumped max_tokens from output token recovery.
    # Default raised from 8K → 32K so OSA can produce longer, more detailed
    # responses without truncation by default. Override via:
    #   config :optimal_system_agent, :max_response_tokens, <int>
    # if a provider's ceiling is tighter (e.g. some Ollama cloud models).
    # Explicit config wins (same "config over effort clamp" fix as
    # max_iterations); otherwise fall back to the effort ceiling.
    Process.get(:osa_bumped_max_tokens) ||
      Application.get_env(:optimal_system_agent, :max_response_tokens) ||
      Effort.max_response_tokens()
  end

  # Cooperative pause flag (WS pause parity) — set by POST /agents/:id/pause,
  # cleared by /resume. Checked once per iteration; when set the loop soft-stops
  # and returns instead of hanging on :sys.suspend.
  defp paused?(sid) when is_binary(sid) do
    match?([{^sid, true}], :ets.lookup(:osa_agent_pause_flags, sid))
  rescue
    ArgumentError -> false
  end

  defp paused?(_), do: false

  @doc """
  Run the agent loop for the given state.

  Returns `{response_string, updated_state}`.
  """
  @spec run(map()) :: {String.t(), map()}
  def run(%{iteration: iter, session_id: sid} = state) do
    # `truncations` is a PER-TURN count — `Observability.turn_end/2` reports it
    # beside `effort` and `reasoning`, which are per-turn conditions. The loop
    # state lives in the `Loop` GenServer across turns, so without this the
    # count would accumulate for the life of the session and the number on a
    # clean turn would be the previous turn's. Zeroed on turn entry only
    # (`run/1` recurses with `iteration + 1`).
    state = if iter == 0, do: Map.put(state, :truncations, 0), else: state

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
        # `Loop.clear_cancel/1`, not a bare `:ets.delete/2`: `Loop.cancel/1`
        # sets the flag across the whole subtree (this session + descendants +
        # any `agent:<sid>:` keys), so clearing only the parent key stranded
        # child flags in the table and a re-used child id started life already
        # cancelled. Clearing must be the exact inverse of setting.
        Loop.clear_cancel(sid)

        Bus.emit(:system_event, %{
          event: :agent_cancelled,
          session_id: sid,
          iteration: iter
        })

        finalize_interrupt(state, nil)

      paused?(sid) ->
        Logger.info("[loop] Paused at iteration #{iter} — soft-stopping until resumed")

        Bus.emit(:system_event, %{
          event: :agent_paused,
          session_id: sid,
          iteration: iter
        })

        TerminalSource.halt(
          "Paused at iteration #{iter}. The agent stopped cooperatively; resume it or send a new message to continue.",
          state,
          :control
        )

      # Goal auto-pause: the cross-turn GoalTracker tripped stall detection
      # (identical gap fingerprints) or the run cap — stop burning budget on a
      # goal that isn't making measurable progress instead of looping forever.
      GoalTracker.enabled?(state) and GoalTracker.paused?(sid) ->
        snap = GoalTracker.snapshot(sid)
        reason = Map.get(snap || %{}, :pause_reason, :no_progress)
        Logger.info("[loop] Goal auto-paused (#{reason}) at iteration #{iter}")

        Bus.emit(:system_event, %{
          event: :goal_auto_paused,
          session_id: sid,
          iteration: iter,
          reason: reason
        })

        TerminalSource.halt(
          "Goal auto-paused (#{reason}): no measurable progress across turns. " <>
            "Review the goal and resume, refine it, or send a new instruction.",
          state,
          :control
        )

      # Real budget cap (primitive #29) — abort a single runaway turn mid-loop,
      # not just at the next turn boundary. Only fires when a caller set
      # `max_budget_usd`; default nil = OFF, so long runs are never killed.
      Limits.budget_exceeded?(state) ->
        cost = Float.round(Map.get(state, :session_cost_usd, 0.0) / 1, 4)
        limit = Map.get(state, :max_budget_usd)
        Logger.warning("[loop] Budget cap reached ($#{cost}/$#{limit}) for session #{sid}")

        Bus.emit(:system_event, %{
          event: :budget_limit_reached,
          session_id: sid,
          current_cost: cost,
          limit: limit
        })

        TerminalSource.halt(
          "Stopped: budget cap reached ($#{cost} / $#{limit}). Raise max_budget_usd to continue.",
          state,
          :control
        )

      iteration_cap_reached?(iter, max_iter) ->
        Logger.warning("Agent loop hit max iterations (#{max_iter}) for session #{sid}")

        # Typed terminal event (item 9) so consumers render the iteration-cap stop
        # distinctly rather than as a plain agent_response. Parallels the
        # :budget_limit_reached / :tool_call_cap_exceeded stop events.
        Bus.emit(:system_event, %{
          event: :max_iterations_reached,
          session_id: sid,
          iteration: iter,
          max_iterations: max_iter
        })

        # Forced model-authored wrap-up turn (opencode MAX_STEPS_PROMPT parity):
        # instead of a canned string, make ONE final tools-disabled model call so
        # the user gets a real handoff — what was accomplished, what remains, and
        # a recommended next step — authored from the actual conversation. Falls
        # back to a static line if that call fails.
        forced_wrapup(state, max_iter)

      true ->
        do_iteration(state)
    end
  end

  # --- Private ---

  defp do_iteration(state) do
    Logger.debug(
      "[loop] do_iteration entered for #{state.session_id}, iteration=#{state.iteration}"
    )

    # Mid-turn steer (primitive #32): fold any steer directives queued for this
    # session into history at this step boundary — BEFORE compaction and context
    # build — so the agent adapts on the very next LLM call without the turn
    # being cancelled and in-flight work lost. Persisted into state.messages (not
    # just one-shot context) so the directive is visible for the rest of the turn.
    state = inject_pending_steer(state)

    # WS6: drain background task-notifications at the same step boundary — a
    # BUSY turn sees background completions here; an IDLE loop is handled by
    # Loop.poke/1 instead. The drain is destructive → exactly-once either way.
    state = inject_pending_task_notifications(state)

    # Proactive context compaction: shrink history before building context /
    # calling the model so the window stays under threshold. Complementary to
    # the reactive ContextCollapse fallback in handle_result/3 (413 retry).
    #
    # The window must be the EFFECTIVE one (`effective_context_window/2`), not
    # the trained one. For a LOCAL provider (ollama/lmstudio/llamacpp) the usable
    # window is min(:ollama_num_ctx, trained) — e.g. a qwen3.5 tag advertises a
    # 262k trained window but is served at the 32k num_ctx ceiling. Budgeting
    # against the trained number puts `compact_at` at ~229k, so compaction NEVER
    # fires before Ollama silently truncates the prompt at 32k and the session
    # degrades invisibly (the model just stops seeing its own history). The
    # status-bar meter already uses the effective window
    # (`Loop.Telemetry.provider_context_window/1`); this makes the compaction
    # DECISION agree with the meter instead of drifting ~8x above it.
    state =
      case effective_context_window(state) do
        cw when is_integer(cw) and cw > 0 ->
          cond do
            ProactiveCompaction.should_compact?(state, cw) ->
              before_count = length(state.messages)
              compacted = ProactiveCompaction.compact(state.messages, state.session_id)
              changed? = length(compacted) != before_count

              if changed? do
                Observability.compaction(state, %{
                  strategy: :proactive,
                  messages_before: before_count,
                  messages_after: length(compacted),
                  iteration: state.iteration
                })
              end

              # Flag a real compaction boundary so the terminal handler can inject a
              # post-compaction continuation (cleared when the model continues with a
              # tool call — see the tool-calls branch). Map.put, since the loop state
              # is a plain map that may not have this key at every entry point.
              # `ProactiveCompaction.compact/2` just made one or more summarizer
              # round-trips. They cost real money and used to be recorded
              # nowhere; they now stage into `Accounting`'s side ledger and are
              # billed to this session here. A no-op when nothing was staged.
              %{state | messages: compacted}
              |> refresh_tokens_after_fold(changed?)
              |> Map.put(:just_compacted, changed?)
              |> Map.put(:just_compacted_overflow, false)
              |> Accounting.absorb_side_spend()

            ProactiveCompaction.should_microcompact?(state, cw) ->
              # Warning band: cheap standalone microcompact pass (truncate
              # stale tool results, no LLM call) to delay full compaction.
              # CC parity: apiMicrocompact pre-request pass.
              #
              # `maybe_flush/2` first: the memory flush band is a sub-band of
              # this one, and durable notes must be harvested while the
              # evidence is still verbatim in the window — microcompaction is
              # already lossy. Once per compaction cycle (latched inside
              # Memory.Flush), side-effecting pass-through.
              state
              |> ProactiveCompaction.maybe_flush(cw)
              |> then(
                &%{&1 | messages: OptimalSystemAgent.Agent.Compactor.micro_compact(&1.messages)}
              )

            true ->
              state
          end

        _ ->
          state
      end

    # Start async prefetches while we build context. In fast mode this also
    # grabs cheap workspace/git hints so the first model call is less blind.
    fast_prefetch_task = FastPath.prefetch_async(state)

    # Advance the cross-turn goal tracker once per new top-level turn (iteration 0)
    # so its reverify cadence + stall detection track real turn progress.
    if state.iteration == 0, do: GoalTracker.tick_turn(state.session_id)

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

    Bus.emit(
      :llm_request,
      %{
        session_id: state.session_id,
        iteration: state.iteration,
        # Per-turn iteration ceiling so the TUI can render "iter N/max" and warn
        # as the loop approaches the cap (item 6). max_iter computed just above.
        max_iterations: max_iter,
        model: state.model,
        agent: state.session_id
      },
      Observability.annotate(state, source: "agent.react_loop")
    )

    # OpenTelemetry GenAI chat-request span (no-op unless otel_enabled).
    Observability.otel_model_request(state)

    start_time = System.monotonic_time(:millisecond)

    # The instant this request is ISSUED — the clock that prices it. Taken here,
    # before the call, and never after it: a turn that streams for four minutes
    # across a DeepSeek peak boundary must be billed at the tier it was sent in,
    # not the tier it happened to land in. `System.monotonic_time/1` above cannot
    # serve — it is a duration source with no calendar. See `Accounting.record/3`
    # and `Pricing`'s moduledoc for why the wall clock at accounting time is the
    # wrong answer for every stored turn.
    requested_at = DateTime.utc_now()

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

    # Siblings of `:usage`, not fields inside it, and they were being dropped
    # here. `ClaudeCli` publishes the CLI's authoritative `total_cost_usd` as
    # `:provider_cost_usd` and `CopilotCli` publishes `:provider_quota`; this
    # was the only point that held them, so accounting priced every CLI turn
    # from the rate card instead — `tokens x list price`, which is the wrong
    # number on a Max plan.
    billing_opts =
      case result do
        {:ok, resp} ->
          [
            provider_cost_usd: Map.get(resp, :provider_cost_usd),
            provider_quota: Map.get(resp, :provider_quota),
            requested_at: requested_at
          ]

        # A failed round-trip was still issued, and Anthropic bills the prompt
        # from `message_start` before the failure. The instant it was issued is
        # known either way, so it goes through either way.
        _ ->
          [requested_at: requested_at]
      end

    input_tokens = Map.get(usage, :input_tokens, 0)

    # TEMP measurement instrumentation (OSA_CONTEXT_TRACE=1). No-op when unset.
    OptimalSystemAgent.Agent.Loop.ContextTrace.usage(state.session_id, usage,
      iteration: state.iteration,
      duration_ms: duration_ms,
      state_message_count: length(state.messages || [])
    )

    # Record real token usage + cost for this LLM round-trip and accumulate it
    # into the per-session accounting (primitive #29). Also refreshes
    # last_input_tokens for context-pressure telemetry.
    state = Accounting.record(state, usage, billing_opts)

    # A request that died mid-stream returns no usage (the `_ -> %{}` above is
    # right about what it was handed), but it was still billed: Anthropic
    # delivers the whole prompt cost in `message_start`, before the failure.
    # The provider stages that into the side ledger keyed on session id
    # (`Anthropic.stage_failed_request_spend/1`); this is the first point after
    # the call where we hold both the state and the session id, so bill it
    # here. A no-op when nothing was staged, which is every successful turn.
    state = Accounting.absorb_side_spend(state)

    Bus.emit(
      :llm_response,
      %{
        session_id: state.session_id,
        provider: state.provider,
        model: state.model,
        duration_ms: duration_ms,
        usage: usage,
        agent: state.session_id
      },
      Observability.annotate(state, source: "agent.react_loop")
    )

    # Bridge REAL per-iteration token usage to the SSE topic the TUI listens on
    # (BUG: the live token counter never populated mid-turn). The streaming
    # `:done` path in LLMClient only bridges usage when the provider includes it
    # in the streaming terminator — many providers (and every non-streaming
    # round-trip) don't, so the TUI saw only the char-estimate. This fires for
    # EVERY completed round-trip with usage. `activity.set_tokens` accumulates by
    # delta and is idempotent for a repeated same-value emit, so a provider that
    # ALSO bridged via the streaming path is not double-counted.
    if is_map(usage) and usage != %{} do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{state.session_id}",
        {:osa_event,
         %{
           type: :llm_response,
           session_id: state.session_id,
           duration_ms: duration_ms,
           usage: %{
             input_tokens: Map.get(usage, :input_tokens, 0),
             output_tokens: Map.get(usage, :output_tokens, 0)
           }
         }}
      )
    end

    # OpenTelemetry GenAI chat-response span carrying real token usage
    # (no-op unless otel_enabled).
    Observability.otel_model_response(state, usage)

    Logger.info("[loop] LLM call completed in #{duration_ms}ms (#{input_tokens} input tokens)")

    # Canonicalize the provider's stop reason BEFORE dispatch — see
    # `canonicalize_stop_reason/2`. Every truncation clause below matches on
    # OSA's canonical `"max_tokens"`, and without this only Anthropic ever
    # reached them.
    {result, state} = canonicalize_stop_reason(result, state, usage)

    handle_result(result, state, context)
  end

  # ── Truncation ingest ─────────────────────────────────────────────────────
  #
  # Seven providers, seven spellings of "you ran out of output tokens":
  # Anthropic `max_tokens`, OpenAI-compat `length`, OpenAI Responses
  # `max_output_tokens`, Ollama `length` (as `done_reason`), Gemini
  # `MAX_TOKENS`, Bedrock `max_tokens`, Cohere `MAX_TOKENS`. The clauses below
  # were written against Anthropic's spelling alone, so on OSA's DEFAULT
  # provider (Ollama) truncation recovery was unreachable — measured on
  # `bench/terminalbench/runs/osa-tb20-full89-f6981b61`, where `regex-chess`
  # delivered a mid-sentence fragment as its final answer after a generation
  # that stopped at exactly the 32,768-token ceiling.
  #
  # One place translates the dialect into OSA's canonical `"max_tokens"`; the
  # provider's own word is preserved in `:stop_reason_raw` so telemetry and
  # logs can name what actually came back. Pattern matching stays exhaustive
  # and guard-safe (no function calls in guards) because the value is
  # normalized before dispatch rather than during it.
  defp canonicalize_stop_reason({:ok, resp}, state, usage) when is_map(resp) do
    if StopReason.truncated?(resp) do
      raw = StopReason.raw(resp) || "unknown"
      output_tokens = Map.get(usage || %{}, :output_tokens, 0)

      # LOUD, not debug. Every defect found in this arm of the codebase had
      # been silent; a generation that was cut off is the single condition
      # under which OSA is most likely to present a wrong answer confidently.
      Logger.warning(
        "[loop] TRUNCATED generation — provider stopped at the output ceiling " <>
          "(stop_reason=#{raw}, output_tokens=#{output_tokens}, " <>
          "max_tokens=#{max_response_tokens()}, effort=#{Effort.current()}, " <>
          "iteration=#{state.iteration}, session=#{state.session_id}). " <>
          "This is NOT a complete answer."
      )

      Bus.emit(:system_event, %{
        event: :response_truncated,
        session_id: state.session_id,
        reason: :detected,
        stop_reason: raw,
        output_tokens: output_tokens,
        max_tokens: max_response_tokens(),
        effort: to_string(Effort.current()),
        iteration: state.iteration
      })

      resp =
        resp
        |> Map.put(:stop_reason, "max_tokens")
        |> Map.put(:stop_reason_raw, raw)

      # Counted on state so `turn_end` can report it next to `effort` and
      # `reasoning`, and so the reasoning-only doom-loop guard can tell "the
      # model stopped calling tools" from "the model was cut off".
      state =
        state
        |> Map.put(:turn_truncated, true)
        |> Map.put(:truncations, Map.get(state, :truncations, 0) + 1)

      {{:ok, resp}, state}
    else
      # A generation that ended on its own clears the flag — the guard must
      # only excuse the generation that was ACTUALLY cut off, not every
      # generation after the first truncation of the turn.
      #
      # It also RETIRES any bumped output ceiling. `Process.put(:osa_bumped_
      # max_tokens, …)` is process-scoped and had no expiry, so a single
      # truncation doubled the ceiling for the rest of the session — every
      # subsequent generation, truncated or not, billed at up to 64,000 output
      # tokens. The bump exists to recover a specific cut-off generation; once
      # the model has produced a complete one, the recovery is over and the
      # configured ceiling is the right one again.
      Process.delete(:osa_bumped_max_tokens)

      {{:ok, resp}, Map.put(state, :turn_truncated, false)}
    end
  end

  defp canonicalize_stop_reason(result, state, _usage), do: {result, state}

  # Max tokens recovery — response was truncated, bump limit and retry.
  #
  # GUARD (finding-1 data-loss fix): only handle the no-tool-call truncation
  # here. If the truncated turn ALSO carries tool calls, those may have already
  # run eagerly via the StreamingToolExecutor; injecting only the assistant
  # content and re-running would orphan the completed task and re-execute the
  # side effect. Let that case fall through to the reconciliation clause below,
  # which keeps already-streamed results and fails only the truncated call.
  defp handle_result({:ok, %{stop_reason: "max_tokens"} = resp}, state, _context)
       when state.overflow_retries < 2 and
              (not is_map_key(resp, :tool_calls) or
                 is_nil(:erlang.map_get(:tool_calls, resp)) or
                 :erlang.map_get(:tool_calls, resp) == []) do
    content = Map.get(resp, :content, "")
    current_max = max_response_tokens()
    # Clamp so recovery NEVER shrinks the budget below what the model just had
    # (the default max_response_tokens is now 32_768; a hardcoded 16_384 ceiling
    # would HALVE it and make truncation loop). Grow-only, doubling up to 64_000.
    bumped = max(current_max, min(current_max * 2, 64_000))

    Logger.info(
      "[loop] Response truncated (stop_reason=max_tokens), bumping max_tokens #{current_max} → #{bumped}"
    )

    # Typed observability event (item 7) so the truncate-and-continue path is
    # visible instead of a silent re-call.
    Bus.emit(:system_event, %{
      event: :response_truncated,
      session_id: state.session_id,
      reason: :max_tokens_bump,
      old_max_tokens: current_max,
      new_max_tokens: bumped,
      iteration: state.iteration
    })

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

  # TRUNCATION, CONTINUATION BUDGET EXHAUSTED — the last honest stop.
  #
  # The clause above continues a truncated generation twice, doubling the
  # ceiling each time (32,768 → 64,000, the cap). Past that, continuing again
  # is an unbounded spend on a generation that has already shown it will not
  # converge — output tokens are the expensive half, and this is the exact
  # shape of a runaway.
  #
  # But the alternative is NOT to hand the fragment over as the answer. That is
  # precisely the defect: on `regex-chess` the delivered "final answer" was one
  # mid-sentence clause — "Let me investigate the en-passant behavior in
  # python-chess…" — after a 350,880-character thinking block, and the
  # deliverable was never written. A truncated fragment presented as complete
  # is worse than no answer, because nothing downstream can tell.
  #
  # So the content is delivered MARKED. The marker is appended, never
  # substituted: the partial text is often most of a real answer and throwing
  # it away loses genuine work. What must not survive is the impression that it
  # is finished.
  defp handle_result({:ok, %{stop_reason: "max_tokens"} = resp}, state, _context)
       when not is_map_key(resp, :tool_calls) or
              (is_map_key(resp, :tool_calls) and
                 (is_nil(:erlang.map_get(:tool_calls, resp)) or
                    :erlang.map_get(:tool_calls, resp) == [])) do
    raw = Map.get(resp, :stop_reason_raw, "max_tokens")
    content = Map.get(resp, :content) || ""

    Logger.error(
      "[loop] Truncated response after #{state.overflow_retries} continuation attempt(s) " <>
        "(stop_reason=#{raw}, max_tokens=#{max_response_tokens()}) — delivering it MARKED " <>
        "as incomplete rather than as a final answer (session: #{state.session_id})"
    )

    Bus.emit(:system_event, %{
      event: :response_truncated,
      session_id: state.session_id,
      reason: :continuation_budget_exhausted,
      stop_reason: raw,
      overflow_retries: state.overflow_retries,
      max_tokens: max_response_tokens(),
      iteration: state.iteration
    })

    marked =
      String.trim_trailing(content) <>
        "\n\n[INCOMPLETE: this response was cut off at the output-token limit " <>
        "(#{max_response_tokens()} tokens, provider stop reason `#{raw}`) after " <>
        "#{state.overflow_retries} continuation attempt(s). It is a fragment, not a " <>
        "finished answer, and any task it describes should be assumed unfinished.]"

    finish_turn(marked, state)
  end

  # TRUNCATED-MESSAGE tool-call guard (PI primitive — correctness).
  #
  # When a model response is cut off by the token limit, the provider can hand
  # back tool-call JSON that happens to parse as valid while its arguments are
  # actually partial. Executing it would run a tool with WRONG/partial input.
  # Per PI's pattern, when the stop reason signals truncation (Anthropic
  # "max_tokens" / OpenAI-compat "length") and the message carries tool calls,
  # FAIL every tool call instead of executing any, then return a continuation
  # directive so the model re-emits complete calls.
  #
  # Ordered after the max_tokens bump-and-retry clause above: a first-pass
  # "max_tokens" truncation still gets a larger budget there (it drops the
  # partial tool calls); this clause catches the tool-call cases that one does
  # not — OpenAI-compat "length", or "max_tokens" past the overflow-retry cap.
  defp handle_result(
         {:ok, %{tool_calls: tool_calls, stop_reason: stop_reason} = resp},
         state,
         _context
       )
       when is_list(tool_calls) and tool_calls != [] and stop_reason in ["max_tokens", "length"] do
    Logger.warning(
      "[loop] Truncated response (stop_reason=#{stop_reason}) carried #{length(tool_calls)} " <>
        "tool call(s) — failing all to avoid executing partial arguments; requesting re-emit"
    )

    # Typed observability event (item 7) so the truncated-tool-call re-emit path
    # is visible to the TUI/analytics instead of a silent re-call.
    Bus.emit(:system_event, %{
      event: :response_truncated,
      session_id: state.session_id,
      reason: :tool_call_reemit,
      stop_reason: stop_reason,
      iteration: state.iteration
    })

    # Same duplicate-id repair as the normal tool-call path: `tool_msgs` below is
    # built one-per-tool_call, so a collision would emit two `tool_result`s
    # carrying the same `tool_call_id` against a single `tool_use` block.
    tool_calls = ToolOrchestrator.uniquify_ids(tool_calls)

    content = Map.get(resp, :content) || ""
    assistant_msg = %{role: "assistant", content: content, tool_calls: tool_calls}

    # Reconcile with the streaming tool executor. Complete tool_use blocks are
    # executed EAGERLY as they stream — BEFORE the terminal stop_reason is known.
    # So some of this turn's tool calls may have ALREADY run (real side effects
    # like file_write / shell_execute). Failing them all and asking the model to
    # re-emit would DUPLICATE those side effects and orphan any still-running
    # task. Instead: keep the real results for calls that already streamed, and
    # only fail the trailing call(s) whose arguments the token limit actually cut
    # off (those never started). Best-effort: on any error, fall back to the
    # original "fail all + re-emit" behavior.
    {streamed_msgs_by_id, streamed_ids} =
      try do
        case Process.get(:osa_streaming_tool_ctx) do
          nil ->
            {%{}, MapSet.new()}

          streaming_ctx ->
            collected = StreamingToolExecutor.collect_results(streaming_ctx)

            by_id =
              streaming_ctx.order
              |> Enum.zip(collected)
              |> Map.new(fn {id, {tool_msg, _result_str}} -> {id, tool_msg} end)

            {by_id, MapSet.new(streaming_ctx.order)}
        end
      rescue
        _ -> {%{}, MapSet.new()}
      catch
        :exit, _ -> {%{}, MapSet.new()}
      end

    Process.delete(:osa_streaming_tool_ctx)

    truncated_fail = fn tc ->
      %{
        role: "tool",
        tool_call_id: tc.id,
        content:
          "Error: tool call not executed — the assistant message was truncated by the token " <>
            "limit, so the arguments may be incomplete. Re-issue this call with complete arguments."
      }
    end

    {tool_msgs, kept_any?} =
      Enum.map_reduce(tool_calls, false, fn tc, kept? ->
        if MapSet.member?(streamed_ids, tc.id) do
          # Already executed during streaming — keep its real result.
          case Map.get(streamed_msgs_by_id, tc.id) do
            nil -> {truncated_fail.(tc), kept?}
            tool_msg -> {tool_msg, true}
          end
        else
          {truncated_fail.(tc), kept?}
        end
      end)

    directive = %{
      role: "user",
      content:
        if kept_any? do
          "[System: Your previous message was truncated by the token limit. Any tool call that " <>
            "had already completed was executed and its result is included above; the trailing " <>
            "call(s) marked with a truncation error were NOT executed. Re-emit ONLY those " <>
            "incomplete tool call(s) now.]"
        else
          "[System: Your previous message was truncated by the token limit before the tool " <>
            "call(s) finished. None were executed, because their arguments may be incomplete. " <>
            "Re-emit the complete tool call(s) now.]"
        end
    }

    state = %{
      state
      | messages: state.messages ++ [assistant_msg] ++ tool_msgs ++ [directive],
        iteration: state.iteration + 1
    }

    run(state)
  end

  # No tool calls — final response or behavioural nudge

  # Mid-conversation steering is sent as `user`, not `system`.
  #
  # Anthropic rejects a `system` message that follows assistant TEXT:
  #
  #     messages.N: role 'system' must follow a 'user' message or an
  #     assistant message ending in a server tool result
  #
  # Bisected against the live API: after a tool result it is accepted; after an
  # assistant text answer it is a hard 400. Gemini behaves the same way. Every
  # site below appends `[assistant(text), steer]`, so on those two families the
  # request failed — meaning OSA's auto-continue, zero-tool gate and
  # verification gate NEVER RAN AT ALL there. The harness had been developed
  # against model families that happen to tolerate an invalid shape.
  #
  # `user` is also the honest role: these are instructions injected into the
  # conversation, not part of the system prompt. The same correction was made
  # to the compaction boundary for a related reason — a leading `system`
  # message was being absorbed into Anthropic's system block behind the cache
  # breakpoints.
  #
  # Note for compaction: turn boundaries are counted at `role: "user"`, so
  # these injected steers now register as boundaries. That is consistent with
  # how the compact boundary is already handled.
  defp handle_result({:ok, %{content: content, tool_calls: []}}, state, _context) do
    # Capture whether the model produced NO visible answer (pure reasoning / an
    # empty generation) BEFORE we substitute a "..." placeholder. This is what
    # distinguishes a genuine reasoning-only spin (wasted generation) from a
    # normal final text answer — the reasoning-only doom-loop guard keys on it.
    visible_empty? = is_nil(content) or String.trim(content) == ""
    content = if is_nil(content) or String.trim(content) == "", do: "...", else: content

    content =
      if Scratchpad.inject?(state) do
        Scratchpad.process_response(content, state.session_id)
      else
        content
      end

    content = if String.trim(content) == "", do: "...", else: content

    # Computed once, before the `cond`, because the clause needs BOTH the
    # boolean and the reason it fired, and a `cond` clause cannot bind.
    announcement = Guardrails.announcement_continue(content, state.messages)
    announcement_spent = Map.get(state, :announcement_continues, 0)

    # An exhausted cap must be LOUD. One nudge is the whole budget, so this
    # backstop is done — and "the model announced again after being told" and
    # "the model reported a result" are different endings that used to look
    # identical from outside. Emitted before the `cond` so it is recorded even
    # though the announcement clause below will decline; a LATER clause
    # (`VerificationGate`, the reasoning-only backstop) may still continue the
    # turn for a reason of its own, which is why this says only that the
    # announcement budget is spent, not that the turn is over.
    if match?({:continue, _}, announcement) and
         announcement_spent >= @max_announcement_continues do
      {:continue, reason} = announcement

      Logger.info(
        "[loop] Announcement backstop EXHAUSTED (#{reason}) — the answer still announces " <>
          "the next action after #{announcement_spent} nudge(s); this backstop will not " <>
          "continue it again (iteration #{state.iteration})"
      )

      Bus.emit(:system_event, %{
        event: :announcement_continue_exhausted,
        session_id: state.session_id,
        reason: reason,
        iteration: state.iteration,
        nudges_spent: announcement_spent,
        answer_preview: String.slice(content, 0, 200)
      })
    end

    cond do
      prose_continue?(state) and state.auto_continues < 2 and
          Guardrails.wants_to_continue?(content) ->
        Logger.info(
          "[loop] Auto-continue: model described intent without tool calls (nudge #{state.auto_continues + 1}/2)"
        )

        nudge = %{
          role: "user",
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

      prose_continue?(state) and state.auto_continues < 3 and Guardrails.code_in_text?(content) ->
        Logger.info(
          "[loop] Coding nudge: model wrote code in markdown instead of calling file_write/file_edit (nudge #{state.auto_continues + 1}/3)"
        )

        nudge = %{
          role: "user",
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

      prose_continue?(state) and
        Map.get(state, :zero_tool_gate_prompts, 0) < @max_zero_tool_gate_prompts and
          Guardrails.needs_verification_gate?(state) ->
        Logger.info(
          "[loop] Verification gate: iteration #{state.iteration}, task context present, zero successful tools — injecting verification"
        )

        verification = %{
          role: "user",
          content:
            "[System: VERIFICATION REQUIRED — You completed #{state.iteration} iterations with a task/goal " <>
              "but executed zero tools successfully. Before returning a final response, verify your answer: " <>
              "use at least one tool (e.g. file_read, dir_list, shell_execute) to confirm your response is accurate. " <>
              "Do NOT return a final answer without tool-backed evidence.]"
        }

        state =
          %{
            state
            | messages: state.messages ++ [%{role: "assistant", content: content}, verification],
              iteration: state.iteration + 1,
              auto_continues: 2
          }
          |> Map.put(
            :zero_tool_gate_prompts,
            Map.get(state, :zero_tool_gate_prompts, 0) + 1
          )

        run(state)

      # `content` is passed so the gate can read the explicit
      # `NO_RUNNABLE_TEST:` escape out of the answer the turn would end on.
      VerificationGate.needs_verification?(state, content) ->
        {directive, state} = VerificationGate.build_directive(state, content)

        state = %{
          state
          | messages: state.messages ++ [%{role: "assistant", content: content}, directive],
            iteration: state.iteration + 1
        }

        run(state)

      # Announcement backstop: the answer ANNOUNCES the next action instead of
      # reporting a result — "I have enough understanding. Let me write the
      # implementation now." — and then the turn ends and nothing writes it.
      #
      # This is NOT `prose_continue?`. That flag gates three clauses that key on
      # wording alone and fire on ordinary explanatory prose, which is why it is
      # off by default and stays off. `announcement_only?/1` is the conjunction
      # of that wording with brevity, and that conjunction is the shipped
      # `announced_next_action` detector: 9 of 34 model failures, 0 of 49 solves
      # on the reference run (`docs/research/failure-taxonomy.md` §7).
      #
      # WHICH sessions is decided by `Guardrails.announcement_continue/2`, which
      # admits exactly two shapes and names the one that fired:
      #
      #   * `:interrupted_task` — the session ran real work and then announced
      #     the next step. `torch-pipeline-parallelism` had 29 turns of tool
      #     calls behind its announcement.
      #   * `:unstarted_task` — a coding request whose first answer announces
      #     the first action with NO tool call anywhere in the session.
      #     `path-tracing` in `runs/VOID-contended-probe-minimal-04061c68`:
      #     one generation, zero tools, $0.00174, "I'll start by examining the
      #     image…", `[DONE]`. That run's binary already had this backstop; it
      #     was blocked by the `not talked_only?` conjunct, which a session that
      #     has never called a tool trivially fails.
      #
      # A conversation is neither. "Let me check the configuration: the value
      # lives in config/runtime.exs and is read at boot" is a complete answer to
      # a question, and `TextOnlyTurnTerminationTest` pins it at exactly one
      # round trip — the `:unstarted_task` shape stays off it because the
      # request asks for an explanation, not a code change.
      #
      # ONE nudge per turn. The failure it addresses is a turn that ended one
      # step early, and one step is what it gives back; a model that announces
      # again after being told is choosing to (and says so on the wire —
      # `:announcement_continue_exhausted`, emitted above), and the answer has
      # already streamed to the user either way.
      announcement_spent < @max_announcement_continues and
          match?({:continue, _}, announcement) ->
        {:continue, reason} = announcement

        Logger.info(
          "[loop] Announcement backstop (#{reason}): answer announces the next action " <>
            "instead of reporting a result — continuing once (iteration #{state.iteration})"
        )

        Bus.emit(:system_event, %{
          event: :announcement_continue,
          session_id: state.session_id,
          reason: reason,
          iteration: state.iteration,
          answer_preview: String.slice(content, 0, 200)
        })

        nudge = %{
          role: "user",
          content:
            "[System: your answer announced what you were about to do rather than " <>
              "reporting what you did, and you called no tools — so nothing happened. " <>
              "This may be the last turn of this session; there is no guarantee anything " <>
              "will run after it. DO THE THING NOW by calling the tools, then report the " <>
              "result. If you genuinely are finished, say what you produced and where it " <>
              "is, without announcing further steps.]"
        }

        state = %{
          state
          | messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
            iteration: state.iteration + 1
        }

        state = Map.put(state, :announcement_continues, announcement_spent + 1)

        run(state)

      # Reasoning-only spin backstop: the model produced NO visible answer AND no
      # tool calls — a wasted, pure-reasoning generation. A real text answer
      # (non-empty content) is normal termination and MUST NOT count, so this is
      # guarded on `visible_empty?`; the streak resets on any tool call (see the
      # tool-calls clause). Bounded by ReasoningOnly.threshold/0: below it we
      # nudge for concrete progress and loop; at it we stop with an honest handoff
      # rather than burning the budget in thought.
      visible_empty? ->
        case DoomLoop.ReasoningOnly.check([], state) do
          {:halt, msg, state} ->
            Bus.emit(:system_event, %{
              event: :reasoning_only_halt,
              session_id: state.session_id,
              iteration: state.iteration
            })

            # THE schemelike join point. `msg` is the guard's advisory —
            # "3 consecutive generations produced no tool calls" — a note the
            # harness wrote to itself about its own control flow. It was
            # delivered to the user as the model's final answer. Marked, so it
            # can never again be rendered as one.
            TerminalSource.halt(msg, state, :guard)

          {:ok, state} ->
            nudge = %{
              role: "user",
              content:
                "[System: your last generation produced no answer and called no tools. " <>
                  "Either give a concrete answer now, or call a specific tool to make " <>
                  "progress. Do not respond with only reasoning.]"
            }

            state = %{
              state
              | messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
                iteration: state.iteration + 1
            }

            run(state)
        end

      # NOTE — the goal-level verifier used to re-enter `run/1` from HERE, after a
      # text-only response. That produced the double-ending defect: the model's
      # "Done. Here's what I set up: …" had ALREADY streamed to the user
      # (`LLMClient.llm_chat_stream` broadcasts every `:text_delta` live, so a
      # presented conclusion cannot be un-presented), the panel then ran, gated,
      # and the turn worked on and delivered a SECOND closing summary. One turn,
      # two endings.
      #
      # The gate now runs at the TOOL-RESULT boundary instead — see
      # `continue_after_tools/4`. Verification therefore happens BEFORE the model
      # writes its conclusion, and its findings are in context when that single
      # conclusion is generated. Nothing re-enters the loop after a response has
      # been shown.

      # CC token-budget "work to target": when an explicit output-token target is
      # set and the accumulated output is under it, auto-continue instead of
      # stopping early. Default OFF (no target → never fires). Bounded by
      # @max_target_continues and the iteration cap.
      token_target_unmet?(state) ->
        target = target_output_tokens(state)

        Logger.info(
          "[loop] Token-budget continue: output " <>
            "#{Map.get(state, :session_output_tokens, 0)}/#{target} " <>
            "(nudge #{Map.get(state, :target_continues, 0) + 1}/#{@max_target_continues})"
        )

        nudge = %{
          role: "user",
          content:
            "[System: You have an output-token target of #{target} tokens for this task and are " <>
              "under it. Keep working toward it — continue with the next concrete step or add depth/" <>
              "verification; do not stop early. If the task is genuinely complete, say so explicitly.]"
        }

        state =
          %{
            state
            | messages: state.messages ++ [%{role: "assistant", content: content}, nudge],
              iteration: state.iteration + 1
          }
          |> Map.put(:target_continues, Map.get(state, :target_continues, 0) + 1)

        run(state)

      # Post-compaction auto-continue (opencode parity): a turn that just crossed a
      # compaction boundary and then produced no tool calls gets one synthetic
      # "continue or ask" turn so a long task doesn't stall at the boundary. The
      # flag is cleared here so it fires exactly once PER COMPACTION — and the
      # per-turn budget below bounds how many compactions may buy one.
      just_compacted?(state) and ProactiveCompaction.continuation_enabled?() and
          turn_continues_left?(state) ->
        spent = Map.get(state, :compaction_continues, 0) + 1

        Logger.info(
          "[loop] Post-compaction continue: resuming the turn across the fold " <>
            "(#{spent}/#{max_turn_continues()}, iteration #{state.iteration})"
        )

        Observability.emit(
          :system_event,
          %{
            event: :compaction_continue,
            continues_spent: spent,
            max_continues: max_turn_continues(),
            overflow: Map.get(state, :just_compacted_overflow, false),
            iteration: state.iteration
          },
          state,
          source: "agent.compaction"
        )

        cont =
          ProactiveCompaction.continuation_message(
            overflow: Map.get(state, :just_compacted_overflow, false),
            session_id: state.session_id
          )

        state =
          %{
            state
            | messages: state.messages ++ [%{role: "assistant", content: content}, cont],
              iteration: state.iteration + 1
          }
          |> Map.put(:just_compacted, false)
          |> Map.put(:just_compacted_overflow, false)
          |> Map.put(:compaction_continues, spent)

        run(state)

      # Budget spent. End the turn on the model's own answer rather than
      # continuing it again — and SAY that the budget is what ended it, so a
      # turn that stopped mid-task is distinguishable from one that finished.
      just_compacted?(state) and ProactiveCompaction.continuation_enabled?() ->
        spent = Map.get(state, :compaction_continues, 0)

        Logger.warning(
          "[loop] Post-compaction continue EXHAUSTED — the turn has crossed " <>
            "#{spent} compaction boundary/ies and will not be continued again " <>
            "(iteration #{state.iteration}). If the task is unfinished, the next " <>
            "user turn resumes it from the compacted history."
        )

        Observability.emit(
          :system_event,
          %{
            event: :compaction_continue_exhausted,
            continues_spent: spent,
            max_continues: max_turn_continues(),
            iteration: state.iteration,
            answer_preview: String.slice(to_string(content), 0, 200)
          },
          state,
          source: "agent.compaction"
        )

        state =
          state
          |> Map.put(:just_compacted, false)
          |> Map.put(:just_compacted_overflow, false)

        finish_turn(content, state)

      # Goal-anchored re-entry. The model produced a final, tool-call-free answer,
      # but an explicitly anchored goal (`GoalTracker.start/2`, via `/goal` or the
      # `progress_note` goal path) is still live and has NOT been judged complete.
      # Continue toward the goal instead of ending the turn.
      #
      # Why this is not the double-ending defect described above: that defect was
      # the goal VERIFIER re-entering here to bolt a second closing summary onto a
      # conclusion the user had already been shown, unasked. This clause fires only
      # when the operator explicitly anchored a goal, and "keep working past an
      # intermediate answer" is the entire thing they asked for. It is opt-in, it
      # spends the shared per-turn budget above, and the tracker — not the model —
      # decides when to stop.
      #
      # The stop condition is deliberately NOT the model saying it is done.
      # `GoalTracker.continue?/1` is false only for `:completed` (which only
      # `GoalVerifier`'s independent skeptic panel can set, via `advance/2`) or
      # `:paused` (stall fingerprint / lifetime run cap / manual). A model that
      # writes "the goal is complete" in its answer does not end this loop.
      goal_continue_due?(state) and turn_continues_left?(state) ->
        sid = state.session_id
        spent = Map.get(state, :compaction_continues, 0) + 1
        snap = GoalTracker.snapshot(sid)

        Logger.info(
          "[loop] Goal continue: resuming toward the anchored goal " <>
            "(#{spent}/#{max_turn_continues()}, iteration #{state.iteration})"
        )

        Observability.emit(
          :system_event,
          %{
            event: :goal_continue,
            session_id: sid,
            continues_spent: spent,
            max_continues: max_turn_continues(),
            goal_id: Map.get(snap || %{}, :goal_id),
            status: Map.get(snap || %{}, :status),
            iteration: state.iteration
          },
          state,
          source: "agent.goal"
        )

        state =
          %{
            state
            | messages:
                state.messages ++
                  [
                    %{role: "assistant", content: content},
                    goal_continuation_message(snap)
                  ],
              iteration: state.iteration + 1
          }
          |> Map.put(:compaction_continues, spent)

        run(state)

      # Budget spent. End the turn on the model's own answer rather than driving
      # it again, and SAY that the budget is what ended it — a goal left unfinished
      # by an exhausted budget must be distinguishable from a goal judged complete.
      # The goal itself stays `:active` on disk, so the next turn resumes it.
      goal_continue_due?(state) ->
        sid = state.session_id
        spent = Map.get(state, :compaction_continues, 0)

        Logger.warning(
          "[loop] Goal continue EXHAUSTED — #{spent} synthetic continuation(s) spent " <>
            "this turn (iteration #{state.iteration}); the goal is still active and the " <>
            "next turn resumes it."
        )

        Observability.emit(
          :system_event,
          %{
            event: :goal_continue_exhausted,
            session_id: sid,
            continues_spent: spent,
            max_continues: max_turn_continues(),
            iteration: state.iteration,
            answer_preview: String.slice(to_string(content), 0, 200)
          },
          state,
          source: "agent.goal"
        )

        finish_turn(content, state)

      true ->
        finish_turn(content, state)
    end
  end

  # Terminal finish for a no-tool-call turn: run stop hooks (which may override
  # the response or force continuation), else return the content as the final
  # answer. Extracted so both the clean `true ->` path and the GoalVerifier
  # `{:pass, _}` path share one copy of the stop-hook dispatch.
  defp finish_turn(content, state) do
    content =
      if VerificationGate.blocked_finish?(state, content) do
        VerificationGate.finish_receipt(state, content)
      else
        content
      end

    case run_stop_hooks(content, state) do
      {:continue, inject_msg, state} ->
        state = %{
          state
          | messages: state.messages ++ [%{role: "assistant", content: content}, inject_msg],
            iteration: state.iteration + 1
        }

        run(state)

      {:override, new_content, state} ->
        {new_content, state}

      {:ok, state} ->
        {content, state}
    end
  end

  # Goal-level verifier gate — smart activation lives in `GoalVerifier` so this
  # sensitive file stays a thin delegation. Resolution precedence (operator
  # override wins): explicit `config :optimal_system_agent,
  # goal_verifier_enabled: true|false` is honored verbatim; otherwise `:auto`
  # (the default) turns the panel ON for autonomous/long-running work
  # (overdrive/bypass mode, an anchored goal loop, or a turn past
  # `goal_verifier_activate_after_iterations`) and OFF for cheap interactive
  # turns. The per-turn run cap / stall early-exit
  # (`GoalVerifier.needs_verification?/1`) and the reverify cadence
  # (`GoalTracker.reverify_due?/1`) still gate on top, so "active" never means
  # "runs every iteration".
  #
  # Public (not `defp`) so this decision is directly unit-testable without
  # spinning up a full loop/session — `@doc false` keeps it out of the
  # module's public docs.
  @doc false
  @spec goal_verifier_enabled?(map()) :: boolean()
  def goal_verifier_enabled?(state), do: GoalVerifier.activated?(state)

  # Rewrite image/video/audio/file content blocks to "[Attached <type>]" text
  # placeholders so a media-heavy history can be retried after a media-driven
  # overflow instead of dead-ending. Matches the compactor's summary-call strip
  # shape so the model sees an identical marker from either path. No-op for
  # plain-string content or non-media blocks.
  @media_block_types ~w(image video audio file)

  defp strip_media_from_messages(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      case Map.get(msg, :content) do
        blocks when is_list(blocks) ->
          Map.put(msg, :content, Enum.map(blocks, &strip_media_block/1))

        _ ->
          msg
      end
    end)
  end

  defp strip_media_from_messages(messages), do: messages

  defp strip_media_block(%{"type" => t}) when t in @media_block_types do
    %{"type" => "text", "text" => "[Attached #{t}]"}
  end

  defp strip_media_block(%{type: t}) when t in @media_block_types do
    %{"type" => "text", "text" => "[Attached #{t}]"}
  end

  defp strip_media_block(block), do: block

  # CC token-budget "work to target". `target_output_tokens` comes from the state
  # (a caller can set it per-session) or the app env; nil/0 = off (never fires).
  defp token_target_unmet?(state) do
    case target_output_tokens(state) do
      target when is_integer(target) and target > 0 ->
        Map.get(state, :target_continues, 0) < @max_target_continues and
          Map.get(state, :session_output_tokens, 0) < target

      _ ->
        false
    end
  end

  defp target_output_tokens(state) do
    Map.get(state, :target_output_tokens) ||
      Application.get_env(:optimal_system_agent, :target_output_tokens)
  end

  defp just_compacted?(state), do: Map.get(state, :just_compacted, false) == true

  # THE per-turn continuation budget — ONE counter, shared by every clause that
  # re-enters `run/1` after the model already produced a final, tool-call-free
  # answer. Currently two such clauses: the post-compaction resume and the
  # goal-anchored resume.
  #
  # Compaction is supposed to be invisible to the work, so the turn resumes
  # across the fold — but "resumes across every fold, forever" is a different
  # failure with the same shape as the one it fixes. A session sitting just over
  # the threshold can re-cross it on each iteration, and each crossing used to
  # buy another synthetic turn with no counter of its own; the only thing that
  # ended such a turn was `max_iterations`, which on high effort is in the
  # hundreds. Three is enough for a genuinely long task to fold, resume, and
  # fold again; past that the turn is not making progress the fold caused.
  #
  # The goal clause deliberately spends the SAME counter rather than growing its
  # own. Two independent resume budgets multiply: a turn that may fold 3 times
  # AND resume 3 times toward a goal is 9 synthetic turns, and neither counter
  # can see the other reach its cap. Sharing makes the bound a real bound —
  # after N synthetic continuations from ANY cause, the turn ends on the model's
  # own answer.
  #
  # The field is still named `:compaction_continues` (and the override is still
  # `:compaction_max_continues`) because both predate the goal clause and are
  # asserted on by shipped tests; the NAME is historical, the ROLE is shared.
  @default_max_turn_continues 3

  defp max_turn_continues do
    case Application.get_env(
           :optimal_system_agent,
           :compaction_max_continues,
           @default_max_turn_continues
         ) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_max_turn_continues
    end
  end

  defp turn_continues_left?(state),
    do: Map.get(state, :compaction_continues, 0) < max_turn_continues()

  # Should this turn be driven another step toward an anchored goal?
  #
  # Every conjunct is load-bearing:
  #
  #   * `enabled?/1` — honors the operator's `goal_tracker_enabled` override and
  #     the autonomous-posture default, so an ordinary interactive turn never
  #     silently gains a resume loop.
  #   * `goal_loop?/1` — a REAL goal was anchored by `start/2`. `tick_turn/1`
  #     lazily creates a bare row for EVERY session; without this, every session
  #     in the product would qualify.
  #   * `continue?/1` — `:active` or `:off_track`. False once the skeptic panel
  #     completed the goal, or the tracker paused it on a stall/run cap.
  #
  # Public for direct unit testing without spinning up a loop; `@doc false` keeps
  # it out of the module docs.
  @doc false
  @spec goal_continue_due?(map()) :: boolean()
  def goal_continue_due?(state) when is_map(state) do
    sid = Map.get(state, :session_id)

    is_binary(sid) and sid != "" and
      GoalTracker.enabled?(state) and
      GoalTracker.goal_loop?(sid) and
      GoalTracker.continue?(sid)
  end

  def goal_continue_due?(_), do: false

  # The synthetic turn that carries the goal back into context.
  #
  # It restates the goal verbatim rather than saying "continue": the answer that
  # just ended the turn may have concluded something narrow, and a bare "keep
  # going" invites re-planning from whatever the model last had in view. Same
  # reasoning as `ProactiveCompaction.continuation_message/1`, which states the
  # open plan verbatim for exactly this reason.
  #
  # The body is now Codex's `goals/continuation.md`, rendered by
  # `Agent.Loop.GoalPrompt` — see that module for what was ported verbatim
  # (objective-as-untrusted-data framing, XML escaping, the completion audit's
  # burden-of-proof wording) and what was adapted (Codex reports a token budget;
  # OSA reports verification rounds against the tracker's lifetime cap).
  defp goal_continuation_message(snap) do
    OptimalSystemAgent.Agent.Loop.GoalPrompt.continuation_message(
      snap,
      Map.get(snap || %{}, :session_id)
    )
  end

  # Re-estimate `last_input_tokens` from the freshly-folded history.
  #
  # `ProactiveCompaction.should_compact?/2` reads `last_input_tokens` in
  # preference to any local estimate, and that field is written in exactly one
  # place: `Accounting.maybe_put_last_input/2`, which writes only when the
  # provider reported a POSITIVE input count. A provider that reports no usage
  # at all (`Providers.Cohere`, `Providers.Replicate`, several OpenAI-compat and
  # local servers — the loop already warns about this for budget enforcement)
  # therefore leaves the PRE-compaction occupancy figure standing forever. The
  # threshold check then re-answers "yes" on the next iteration, and the one
  # after, each time buying a full summarizer round-trip to fold a history that
  # is already folded: a compaction loop that fires every iteration, bounded
  # only by the global iteration cap.
  #
  # `TurnPipeline.compact_and_refresh_tokens/1` already does exactly this at the
  # turn boundary (finding #8) — for the same reason and against the same field.
  # This is the missing half: the mid-turn fold.
  @spec refresh_tokens_after_fold(map(), boolean()) :: map()
  defp refresh_tokens_after_fold(state, false), do: state

  defp refresh_tokens_after_fold(state, true) do
    Map.put(
      state,
      :last_input_tokens,
      OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
    )
  rescue
    _ -> state
  end

  # Usable context window for the state's model+provider, in tokens.
  #
  # Delegates to `Loop.ContextWindow.resolve/1` so the compaction DECISION, the
  # displayed context meter, and `Agent.Compactor` share ONE denominator —
  # resolved from `effective_context_window_info/2`, the variant that admits
  # ignorance.
  #
  # An UNKNOWN window resolves to `CompactionThresholds.fallback_window/0`, not
  # to 0.
  #
  # Returning 0 made the caller's `cw > 0` guard skip compaction entirely, and
  # that deferral was deliberate: the behaviour before it fell back to the flat
  # 128k config default, which on a 1M-window model fired a fidelity-destroying
  # summarization at ~11% occupancy, every turn, unrecoverably. Deferring was
  # the right call against that failure.
  #
  # It stopped being the right call once `CompactionThresholds` grew an
  # absolute ceiling. The old objection was that a guess can be an order of
  # magnitude wrong; with the clamp, EVERY window at or above the ceiling
  # produces identical thresholds, so for those models the guess is not
  # approximately right, it is exactly right — `compact_at` is 167,000 whether
  # we know the model has 200k, 1M, or nothing at all. Below the ceiling the
  # guess compacts later than ideal and the reactive ContextCollapse path in
  # handle_result/3 still catches the provider's context-length error, which is
  # a bounded, recoverable error.
  #
  # What it is no longer is fail-OPEN. MEASURED: `glm-4.7:cloud` resolves to
  # `:unknown` — Ollama's /api/show reports no context_length for that tag and
  # it was absent from the static table — so a model this machine is configured
  # to run had compaction silently disabled for the entire life of every
  # session. A safety mechanism must not switch itself off for the models
  # nobody remembered to enumerate.
  #
  # `ContextWindow.resolve/1` itself stays honest and keeps returning
  # `:unknown`; the status meter and every other consumer still see ignorance
  # as ignorance. Only the compaction DECISION substitutes a bounded default.
  @spec effective_context_window(map()) :: non_neg_integer()
  defp effective_context_window(state) do
    case OptimalSystemAgent.Agent.Loop.ContextWindow.resolve(state) do
      {:ok, cw} ->
        cw

      :unknown ->
        fallback = OptimalSystemAgent.Agent.Loop.CompactionThresholds.fallback_window()

        Logger.debug(
          "[loop] context window unknown for model=#{inspect(Map.get(state, :model))} " <>
            "provider=#{inspect(Map.get(state, :provider))} — compacting against the " <>
            "conservative fallback window #{fallback}"
        )

        fallback
    end
  end

  # Forced model-authored wrap-up at the iteration cap. One tools-disabled model
  # turn so the user gets a real state summary + handoff instead of a canned
  # line. Fully guarded (try/rescue/catch + static fallback) so hitting the cap
  # can never itself crash the turn.
  defp forced_wrapup(state, max_iter) do
    directive = %{
      role: "user",
      content:
        "[System: You have reached the maximum of #{max_iter} steps for this task and " <>
          "tools are now DISABLED for this final turn. Do not attempt to call any tool. " <>
          "Write a concise plain-text wrap-up with three parts: (1) what you accomplished, " <>
          "(2) what remains to be done, (3) your recommended next step. Be specific and " <>
          "reference the actual work from this conversation.]"
    }

    try do
      context = cached_context(state)
      messages = context.messages ++ [directive]

      llm_opts = [
        tools: [],
        temperature: LLMClient.temperature(),
        max_tokens: max_response_tokens()
      ]

      # Mirror do_iteration's streaming setup so llm_chat_stream has a valid
      # tool-executor context in the process dict. With tools: [] nothing will
      # actually execute — this is purely to satisfy the streaming contract.
      streaming_ctx = StreamingToolExecutor.start(state)
      Process.put(:osa_streaming_tool_ctx, streaming_ctx)

      case LLMClient.llm_chat_stream(state, messages, llm_opts) do
        {:ok, resp} ->
          content = Map.get(resp, :content, "")

          if is_binary(content) and String.trim(content) != "" do
            {content, state}
          else
            {wrapup_fallback(state, max_iter), state}
          end

        _ ->
          {wrapup_fallback(state, max_iter), state}
      end
    rescue
      # The canned fallback is harness text; the SUCCESS arm above is a real
      # model-authored wrap-up and is deliberately left as `:model`.
      _ -> TerminalSource.halt(wrapup_fallback(state, max_iter), state, :control)
    catch
      :exit, _ -> TerminalSource.halt(wrapup_fallback(state, max_iter), state, :control)
    end
  end

  defp wrapup_fallback(state, max_iter) do
    tools_used = Telemetry.extract_tools_used(state.messages) |> Enum.join(", ")

    "I've used all #{max_iter} iterations on this task.\n\n**Tools used:** #{tools_used}\n\n" <>
      "If the task isn't complete, try breaking it into smaller steps or giving more specific instructions."
  end

  # Tool calls — execute in parallel and loop
  defp handle_result({:ok, %{content: content, tool_calls: tool_calls} = resp}, state, _context)
       when is_list(tool_calls) do
    # Doom-loop resample snapshot: the loop state BEFORE this turn's assistant
    # response (and its tool results) is appended. If a doom-loop is detected
    # below, `Resample` rewinds to this snapshot to DISCARD the offending
    # response and re-roll the turn, up to a bounded budget, before falling back
    # to the existing halt behavior.
    resample_snapshot = state

    # DUPLICATE-ID REPAIR — must happen HERE, before `assistant_msg` is built and
    # before either id-keyed map below (`all_results_map` at the merge, and
    # `ToolOrchestrator.dispatch/3`'s own order-restoring map). Two tool calls
    # sharing an id collapse in both maps, losing one result and orphaning a
    # `tool_use` block, which a strict provider rejects on the NEXT request.
    # Single canonical repair, applied once, upstream of everything.
    tool_calls = ToolOrchestrator.uniquify_ids(tool_calls)

    # Forward progress: a tool call resets the reasoning-only spin streak (the
    # reasoning-only doom-loop backstop counts only wasted, tool-less, empty
    # generations — see the no-tool-call clause above) AND clears the
    # just-compacted flag (the model continued on its own, so no post-compaction
    # continuation is needed). Map.put mirrors the detectors' own state access.
    state =
      %{state | iteration: state.iteration + 1}
      |> Map.put(:reasoning_only_streak, 0)
      |> Map.put(:just_compacted, false)

    content =
      if Scratchpad.inject?(state) do
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
        # Raised from a hardcoded 60s to 300s (config `:tool_timeout_ms`) so a
        # long build/test/install batched into the parallel path isn't killed
        # before shell_execute's own 300s default gets to run.
        # No default ceiling. A five-minute cap killed multi-agent dispatches
        # mid-flight: the wrapper reported a tool timeout and ended the turn
        # while the agents it launched carried on in the background, so the
        # turn lost its own work and nothing else stopped. Tools that need a
        # bound carry their own (shell per-command, provider receive timeouts,
        # bounded_compaction). Set :tool_timeout_ms to reimpose one.
        timeout_ms: Application.get_env(:optimal_system_agent, :tool_timeout_ms, :infinity)
      )

    # Collect streaming tool results (these may already be done). Pair by
    # tool_call_id — NOT by position: collect_results returns results in stream
    # (parse-completion) order, which can differ from the model's final
    # tool_calls order. A positional zip would stamp one tool_call's result with
    # another tool_call's id (one id gets two results, another gets none).
    streaming_results =
      if streaming_ctx && StreamingToolExecutor.has_in_flight?(streaming_ctx) do
        collected = StreamingToolExecutor.collect_results(streaming_ctx)

        results_by_id =
          Map.new(collected, fn result ->
            # `result` is {tool_msg, str} or the fatal {tool_msg, str, {:fatal, _}}
            tool_msg = elem(result, 0)
            {tool_msg[:tool_call_id] || tool_msg["tool_call_id"], result}
          end)

        Enum.map(already_streaming, fn tc ->
          result =
            Map.get(
              results_by_id,
              tc.id,
              {%{role: "tool", tool_call_id: tc.id, content: "Error: Tool not executed"},
               "Error: Tool not executed"}
            )

          {tc, result}
        end)
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

    # NON-FATAL TOOL ERROR contract (Codex parity). Every ordinary tool failure
    # — a raise, a crash, a timeout, a denial, an {:error, _} — has already been
    # synthesized into a readable tool result by ToolExecutor, so the turn just
    # continues below. Only an explicit FATAL result carries the third tuple
    # element; strip it here, keep its tool message (so the assistant's
    # tool_calls are never orphaned in history), and end the turn.
    {results, fatal_message} = ToolError.normalize_results(results)

    tool_messages = Enum.map(results, fn {_tc, {tool_msg, _result_str}} -> tool_msg end)
    state = %{state | messages: state.messages ++ tool_messages}

    if is_binary(fatal_message) do
      handle_fatal_tool_error(fatal_message, state)
    else
      continue_after_tools(results, tool_calls, state, resample_snapshot)
    end
  end

  # FATAL class — the one tool outcome that still aborts the turn.
  defp handle_fatal_tool_error(message, state) do
    Logger.error(
      "[loop] Fatal tool error — aborting turn at iteration #{state.iteration}: #{message}"
    )

    Bus.emit(:system_event, %{
      event: :fatal_tool_error,
      session_id: state.session_id,
      iteration: state.iteration,
      reason: message
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :system_event,
         event: :fatal_tool_error,
         session_id: state.session_id,
         reason: message
       }}
    )

    TerminalSource.halt("The turn stopped on a fatal tool error: #{message}", state, :error)
  end

  defp continue_after_tools(results, tool_calls, state, resample_snapshot) do
    # A successful `tool_search` has to change the NEXT request's tools array,
    # or the tools it just described stay uncallable on every native-tool
    # provider. Done here, at the tool-result boundary, because this is the one
    # join point every executed tool call passes through before the loop
    # decides whether to generate again. See `Loop.ToolDiscovery` for the
    # append-only/never-shrink rules that keep the cached prefix stable.
    state = ToolDiscovery.widen(state, results)

    # A tool ran, so the assistant text before it and the text after it are two
    # different blocks on screen — the tool's own cell is drawn between them.
    # End the segment so the next generation mints a fresh `message_id`.
    #
    # Every OTHER re-entry into `run/1` (the verification gate, an output-token
    # target, a just-crossed compaction boundary, a stop hook) continues the
    # open id, because the user sees one uninterrupted answer and splitting it
    # is what tore a single reply into two `◈ OSA` headers mid-thought.
    LLMClient.start_new_message_segment()

    # Per-iteration context-pressure emit (mid-turn meter fix): previously
    # Telemetry.emit_context_pressure/1 only fired at turn boundaries (loop.ex),
    # so the TUI context bar stayed frozen while a single turn ran many tool
    # calls even though state.messages (and the char-count fallback estimate)
    # grows with every tool result. Emitting here, right after this
    # iteration's tool results are folded into state.messages and before the
    # next model call / recursive run(state), makes the meter climb live.
    # Cheap: at most once per ReAct iteration, and estimate_tokens is a
    # char/word heuristic guarded by emit_context_pressure's own rescue.
    Telemetry.emit_context_pressure(state)

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

      # Even on this fast-return path (no synthesis round-trip), run doom-loop
      # detection so a pathological computer_use-only loop is still caught by the
      # identical-call / absolute call-cap safety net, and so these calls count
      # toward total_tool_calls (DoomLoop.check increments it). Respect a halt.
      case DoomLoop.check(results, tool_calls, state) do
        {:halt, doom_message, halted_state} ->
          Resample.handle(doom_message, halted_state, resample_snapshot, &run/1)

        {:ok, state} ->
          {summary, Map.put(state, :doom_resamples, 0)}
      end
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
        {:halt, doom_message, halted_state} ->
          Resample.handle(doom_message, halted_state, resample_snapshot, &run/1)

        {:ok, state} ->
          # Clean turn — reset the consecutive-resample budget so recovery
          # attempts bound only a *stuck* stretch, not the session lifetime.
          state = Map.put(state, :doom_resamples, 0)

          # Auto-mode: if the safety Guardian paused this session after N blocked
          # dangerous actions, halt the loop and surface a review prompt instead
          # of recursing into another unattended iteration.
          if state.permission_tier == :auto and
               OptimalSystemAgent.Agent.Safety.Guardian.paused?(state.session_id) do
            blocks = OptimalSystemAgent.Agent.Safety.Guardian.block_count(state.session_id)

            pause_message =
              "Auto-mode paused for review: #{blocks} dangerous action(s) were blocked. " <>
                "Review the blocked calls, then resume to continue."

            TerminalSource.halt(pause_message, state, :control)
          else
            # Goal-level verification runs HERE — at the tool-result boundary,
            # before the next generation — and nowhere else. Two reasons:
            #
            #   1. ONE ENDING. Assistant text streams to the user token-by-token,
            #      so a conclusion cannot be retracted once generated. Verifying
            #      after a text response and then looping is what made a turn end
            #      twice. Verifying here puts the panel's findings in context
            #      *before* the model writes its conclusion, so there is exactly
            #      one.
            #   2. CHEAP BY DEFAULT. `maybe_gate/1` is a three-tier gate: free
            #      local skips → one cheap triage call → the expensive skeptic
            #      panel only on `candidate_complete`. It appends at most one
            #      system directive and never raises.
            state = GoalVerifier.maybe_gate(state)
            run(state)
          end
      end
    end
  end

  # WS5 — hard interrupt: LLMClient killed the in-flight stream. Kill any tool
  # tasks the streaming executor had started (their tool_use blocks were never
  # persisted, so discarding keeps history valid), persist the partial text and
  # the interrupt marker, and end the turn.
  defp handle_result({:cancelled, %{content: partial}}, state, _context) do
    Logger.info("[loop] Hard interrupt at iteration #{state.iteration} — aborting turn")

    case Process.get(:osa_streaming_tool_ctx) do
      nil -> :ok
      ctx -> StreamingToolExecutor.discard(ctx)
    end

    Process.delete(:osa_streaming_tool_ctx)

    # Subtree-wide clear — the exact inverse of `Loop.cancel/1`. See the
    # matching call in `run/1`.
    Loop.clear_cancel(state.session_id)

    Bus.emit(:system_event, %{
      event: :agent_cancelled,
      session_id: state.session_id,
      iteration: state.iteration
    })

    finalize_interrupt(state, partial)
  end

  # Turn-level retry budget for a stream idle timeout. Small on purpose: each
  # attempt costs a full generation, and the committed tool results mean the
  # retry resumes rather than restarts.
  @max_idle_timeout_retries 2

  # LLM error — compact and retry or surface error
  defp handle_result({:error, reason}, state, _context) do
    alias OptimalSystemAgent.Agent.Loop.ContextCollapse

    reason_str = if is_binary(reason), do: reason, else: inspect(reason)

    # DURABILITY (defect: executed tool work discarded on the error path).
    # Tools stream-execute EAGERLY, so by the time the LLM call fails their side
    # effects have already happened. Commit their results to message history
    # BEFORE erroring or retrying — Codex's turn retry RESUMES from history
    # rather than replaying, and that is only possible if the outputs are in
    # history first. Without this a retry re-runs `git push` / re-writes files.
    # A no-op when no tool ever streamed (the common case, incl. overflow).
    {state, executed_tools} = commit_streamed_tool_results(state, reason)

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

            # `force: true` — the provider has ALREADY returned a
            # context-length error, so this is the real overflow signal the
            # compactor's `:unknown`-window deferral policy waits for. Compact
            # even when the window cannot be resolved; the threaded window
            # still sizes the target when it CAN be.
            OptimalSystemAgent.Agent.ContextEngine.Router.maybe_compact(
              state.messages,
              Map.get(state, :last_input_tokens, 0),
              state.session_id,
              context_window: OptimalSystemAgent.Agent.Loop.ContextWindow.resolve(state),
              force: true
            )
        end

      # Media-strip replay (opencode compaction.ts replay parity): a media-driven
      # overflow won't shrink from tool-result collapse alone, so rewrite any
      # image/video/audio/file blocks in the history to "[Attached <type>]" text
      # placeholders before retrying. Idempotent (placeholders are plain text) and
      # a no-op when there is no media.
      state =
        %{
          state
          | messages: strip_media_from_messages(collapsed_messages),
            overflow_retries: retry_num
        }
        |> Map.put(:just_compacted, true)
        |> Map.put(:just_compacted_overflow, true)

      run(state)
    else
      if context_overflow?(reason_str) do
        Logger.error("Context overflow after 3 recovery attempts (iteration #{state.iteration})")

        Observability.emit(
          :system_event,
          %{event: :error, kind: :context_overflow, iteration: state.iteration},
          state,
          source: "agent.react_loop"
        )

        TerminalSource.halt(
          "I've exceeded the context window. Try breaking your request into smaller parts.",
          state,
          :error
        )
      else
        idle_attempt = Map.get(state, :idle_timeout_retries, 0) + 1

        if idle_timeout?(reason) and idle_attempt <= @max_idle_timeout_retries do
          # RETRYABLE (Codex parity), not terminal. The provider connection went
          # silent; killing the stream task also destroyed the in-task
          # Resilience retries, so the retry decision is re-made here — where the
          # already-executed tool results have just been committed to history, so
          # the retry RESUMES from that history and never re-runs a tool.
          Logger.warning(
            "[loop] Stream idle timeout — retrying turn " <>
              "(#{idle_attempt}/#{@max_idle_timeout_retries}, iteration #{state.iteration}" <>
              if(executed_tools == [],
                do: ")",
                else: ", resuming after #{length(executed_tools)} already-executed tool(s))"
              )
          )

          Observability.emit(
            :system_event,
            %{
              event: :error,
              kind: :llm_idle_timeout,
              category: :timeout,
              retryable: true,
              attempt: idle_attempt,
              max_attempts: @max_idle_timeout_retries,
              resumed_tools: executed_tools,
              iteration: state.iteration
            },
            state,
            source: "agent.react_loop"
          )

          state
          |> Map.put(:idle_timeout_retries, idle_attempt)
          |> Map.put(:iteration, state.iteration + 1)
          |> run()
        else
          Logger.error("LLM call failed: #{reason_str}")

          category = OptimalSystemAgent.Providers.ErrorCatalog.classify(reason)

          # `kind` is ATTRIBUTION, and it was a lie for a whole class of
          # failures. Not every reason that reaches here is the provider's: an
          # encoding fault (a tool result carrying non-UTF-8 bytes, which
          # `Jason` refuses before any HTTP call), a body OSA assembled wrong,
          # a crash inside a provider module — all arrive as
          # `{:error, "Provider error: …"}` and all used to be stamped
          # `:llm_error`.
          #
          # Downstream that is not cosmetic. The benchmark driver keys on this
          # to set `status: "provider_error"`, so every OSA defect in this
          # class inflated the measured MODEL failure rate and hid itself in
          # the process — in exactly the numbers the current work is being
          # judged by.
          owner = OptimalSystemAgent.Providers.ErrorCatalog.fault_owner(reason)
          kind = if owner == :osa, do: :harness_error, else: :llm_error

          Observability.emit(
            :system_event,
            %{
              event: :error,
              kind: kind,
              category: category,
              # Additive, and the field a consumer should actually read: `kind`
              # keeps its old values for old consumers, `owner` answers the
              # only question attribution cares about.
              owner: owner,
              reason: reason_str,
              iteration: state.iteration
            },
            state,
            source: "agent.react_loop"
          )

          message =
            OptimalSystemAgent.Providers.ErrorCatalog.user_message(reason) <>
              executed_tools_note(executed_tools)

          # Record that this turn ended in a PROVIDER failure, not an answer.
          #
          # Without this the turn is indistinguishable from a successful one:
          # the reply is a human-readable error string, `process_message`
          # returns `{:ok, message}`, and the `done` frame is clean. Measured
          # directly during benchmarking — a turn with 11 retries, the fallback
          # chain exhausted and ZERO tokens exchanged still reported
          # `status: ok` with `saw_done: true`.
          #
          # That is right for a human reading the TUI, who wants to see the
          # error text. It is wrong for anything programmatic: two benchmark
          # harnesses independently scored these as the MODEL failing to
          # produce output, and one nearly published a fake result because the
          # instances that died were the ones the baseline had solved.
          #
          # Carried on state and surfaced as an additive field on the
          # agent_response event, so existing consumers are unaffected and new
          # ones can tell an outage from an answer.
          #
          # `owner` rides along for the same reason it is on the system_event:
          # the driver currently maps ANY `turn_error` to
          # `status: "provider_error"`, which is wrong when the fault is ours.
          # Additive, so a driver that ignores it behaves exactly as before.
          state =
            Map.put(state, :turn_error, %{
              category: category,
              owner: owner,
              reason: reason_str
            })

          # The turn ended in a provider OUTAGE, not an answer. `turn_error`
          # above already says so in a field, but it is dropped by the Rust
          # client (never declared in the SSE struct); the source mark is the
          # carrier that actually reaches a renderer.
          TerminalSource.halt(message, state, :error)
        end
      end
    end
  end

  @doc false
  # Turn-level retry budget for a stream idle timeout. Public for tests.
  def max_idle_timeout_retries, do: @max_idle_timeout_retries

  @doc false
  # True for the structured idle-timeout reason minted by `LLMClient` (and for
  # the legacy bare-string form, and for either wrapped in a `:stream_error`).
  # This is the RETRYABLE classification: an idle stream is a transient
  # connection failure, not a terminal turn error.
  def idle_timeout?({:idle_timeout, _}), do: true
  def idle_timeout?({:stream_error, reason}), do: idle_timeout?(reason)
  def idle_timeout?({:stream_error, reason, _partial}), do: idle_timeout?(reason)
  def idle_timeout?(reason) when is_binary(reason), do: String.contains?(reason, "went silent")
  def idle_timeout?(_), do: false

  # Assistant text that streamed before the failure, when the reason carries it.
  defp idle_partial({:idle_timeout, %{partial: p}}) when is_binary(p), do: p
  defp idle_partial({:stream_error, reason}), do: idle_partial(reason)
  defp idle_partial({:stream_error, reason, _}), do: idle_partial(reason)
  defp idle_partial(_), do: ""

  # Drain the streaming tool executor into message history on the ERROR path.
  # Returns `{state, executed_tool_names}`.
  defp commit_streamed_tool_results(state, reason) do
    ctx = Process.get(:osa_streaming_tool_ctx)

    result = StreamingToolExecutor.drain_to_messages(ctx, idle_partial(reason))
    Process.delete(:osa_streaming_tool_ctx)

    case result do
      {:ok, msgs, names} ->
        Logger.warning(
          "[loop] LLM call failed AFTER #{length(names)} tool(s) had already executed " <>
            "(#{Enum.join(names, ", ")}) — committing their results to history so the turn " <>
            "resumes instead of re-running them"
        )

        {%{state | messages: state.messages ++ msgs}, names}

      :none ->
        {state, []}
    end
  end

  # Appended to a terminal LLM error message when tools already ran this turn.
  # The model reads this back as conversation context, so it must say plainly
  # that the work is done and must not be repeated.
  defp executed_tools_note([]), do: ""

  defp executed_tools_note(names) do
    "\n\n[System: #{length(names)} tool call(s) — #{Enum.join(names, ", ")} — ALREADY EXECUTED " <>
      "before this failure and their results are recorded above. Do NOT run them again; " <>
      "continue from those results.]"
  end

  @interrupt_marker "[Request interrupted by user]"
  @interrupt_marker_tool_use "[Request interrupted by user for tool use]"

  @doc false
  # The synthetic user-marker strings an interrupted turn ends with. Public so
  # Loop.run_and_reply can skip the assistant append for interrupted turns and
  # the TUI contract (is_interrupt_marker in handle_actions.rs) stays in sync.
  def interrupt_markers, do: [@interrupt_marker, @interrupt_marker_tool_use]

  # Port of CC's onCancel ordering (REPL.tsx / messages.ts): [partial assistant
  # text] → [is_error tool_results for orphaned tool_use] → [user interrupt
  # marker]. Returns {marker, state} so the marker doubles as the turn's
  # response string (the TUI renders it as a styled "Interrupted" line).
  defp finalize_interrupt(state, partial) do
    messages = state.messages

    messages =
      if is_binary(partial) and String.trim(partial) != "" do
        messages ++ [%{role: "assistant", content: partial}]
      else
        messages
      end

    {messages, tool_use?} = fill_orphaned_tool_results(messages)

    marker = if tool_use?, do: @interrupt_marker_tool_use, else: @interrupt_marker

    # `scaffold: true` flags this as a synthetic message the loop injected, not
    # something the user typed. `/undo` (and anything else walking back to the
    # last real user turn) can then skip it by FLAG rather than by string-
    # matching the marker text — a content match breaks the moment the wording
    # changes or a user types the marker verbatim.
    state = %{
      state
      | messages: messages ++ [%{role: "user", content: marker, scaffold: true}]
    }

    {marker, state}
  end

  # CC yieldMissingToolResultBlocks: every `tool_use` that never received a
  # `tool_result` gets a synthetic "Interrupted by user" result so the API
  # history stays valid on the next turn.
  #
  # This scans EVERY assistant message, not just `List.last/1`. The last-message
  # check was a latent permanent-corruption bug: `finalize_interrupt/2` appends
  # the partial assistant TEXT before calling here, so an assistant message
  # carrying both streamed text and tool calls was no longer last and its
  # `tool_use` blocks were never filled. A strict provider (Anthropic, Gemini)
  # rejects the whole request over one orphan — and because the transcript is
  # persisted, that rejection then repeats on EVERY subsequent turn, forever.
  #
  # Each synthetic result is inserted IMMEDIATELY AFTER the assistant message
  # that owns it, not appended at the end: Anthropic requires the `tool_result`
  # blocks to be in the message directly following their `tool_use`, so a tail
  # append would trade one invalid transcript for another.
  defp fill_orphaned_tool_results(messages) do
    answered = answered_tool_ids(messages)

    {reversed, filled_any?} =
      Enum.reduce(messages, {[], false}, fn msg, {acc, filled?} ->
        case orphaned_tool_call_ids(msg, answered) do
          [] ->
            {[msg | acc], filled?}

          ids ->
            results =
              Enum.map(ids, fn id ->
                %{role: "tool", tool_call_id: id, content: "Interrupted by user"}
              end)

            # `acc` is reversed, so the results must be pushed in reverse order
            # to land after `msg` in the restored list.
            {Enum.reverse(results) ++ [msg | acc], true}
        end
      end)

    messages = Enum.reverse(reversed)
    {messages, filled_any? or trailing_interrupted_tool?(messages)}
  end

  # Ids of every tool call in `msg` that no `tool` message answers. Tolerates
  # both atom- and string-keyed messages (checkpoint restore decodes to strings)
  # and tool calls missing an id (nothing to answer — skipped).
  defp orphaned_tool_call_ids(msg, answered) do
    case msg_role(msg) do
      "assistant" ->
        msg
        |> tool_calls_of()
        |> Enum.map(&tool_call_id/1)
        |> Enum.reject(&(is_nil(&1) or MapSet.member?(answered, &1)))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp answered_tool_ids(messages) do
    for msg <- messages,
        msg_role(msg) == "tool",
        id = Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id"),
        not is_nil(id),
        into: MapSet.new(),
        do: id
  end

  defp msg_role(msg) when is_map(msg), do: Map.get(msg, :role) || Map.get(msg, "role")
  defp msg_role(_), do: nil

  defp tool_calls_of(msg) do
    case Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp tool_call_id(tc) when is_map(tc), do: Map.get(tc, :id) || Map.get(tc, "id")
  defp tool_call_id(_), do: nil

  # True when the tool batch itself was killed (ToolOrchestrator appended
  # "Error: Interrupted by user" results) — the marker should then say
  # "for tool use".
  defp trailing_interrupted_tool?(messages) do
    case List.last(messages) do
      %{role: "tool", content: content} when is_binary(content) ->
        String.contains?(content, "Interrupted by user")

      _ ->
        false
    end
  end

  # Run Stop hooks (CC protocol). A command hook that exits 2 (or returns
  # decision:"block") surfaces through Dispatch as {:blocked, reason}: the
  # agent must NOT stop — the reason is injected as feedback and the loop
  # continues. `stop_hook_active` is set in the payload on continuation so
  # hook scripts can detect they already blocked once (CC's infinite-loop
  # guard); a hard cap of consecutive stop-hook continuations backstops
  # buggy hooks that ignore the flag.
  @stop_hook_max_continues 5

  defp run_stop_hooks(content, state) do
    continues = Process.get(:osa_stop_hook_continues, 0)

    payload = %{
      content: content,
      session_id: state.session_id,
      iteration: state.iteration,
      turn_count: state.turn_count,
      stop_hook_active: continues > 0
    }

    try do
      case OptimalSystemAgent.Agent.Hooks.run(:stop, payload) do
        {:blocked, reason} when continues < @stop_hook_max_continues ->
          Process.put(:osa_stop_hook_continues, continues + 1)

          inject = %{
            role: "system",
            content: "[Stop hook feedback — do not stop yet]\n" <> to_string(reason)
          }

          {:continue, inject, state}

        {:blocked, reason} ->
          Logger.warning(
            "[loop] Stop hook still blocking after #{continues} continuations — stopping anyway: #{inspect(reason)}"
          )

          clear_stop_hook_state()
          {:ok, state}

        {:ok, %{continue: true, message: msg}} ->
          Process.put(:osa_stop_hook_continues, continues + 1)
          inject = %{role: "system", content: msg}
          {:continue, inject, state}

        {:ok, %{override: new_content}} ->
          clear_stop_hook_state()
          {:override, new_content, state}

        _ ->
          clear_stop_hook_state()
          {:ok, state}
      end
    rescue
      _ -> {:ok, state}
    catch
      :exit, _ -> {:ok, state}
    end
  end

  defp clear_stop_hook_state, do: Process.delete(:osa_stop_hook_continues)

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

  # Explore-first nudge.
  #
  # Two things this used to do, and no longer does.
  #
  # 1. It counted `shell_execute` as a file mutation. `write_without_read?/1`
  #    still classifies it that way for its own callers, so the gate here is
  #    the narrower `Guardrails.blind_file_write?/1`: a first-turn `ls -la /app`
  #    is not a blind write, and telling the model it "modified existing files"
  #    when it ran a read-only command is a false statement injected into its
  #    context. Measured firing on seven bench runs whose first tool call was a
  #    plain shell probe, including `cancel-async-tasks`, which OSA failed.
  #
  # 2. It closed with "read what you changed to verify it's correct" — a
  #    re-read instruction that directly contradicts SYSTEM_LEAN §2.4 ("Never
  #    re-read after a successful edit — the tool errors if it failed, so
  #    success *is* the confirmation"). That sentence bought a whole extra
  #    read turn per firing and taught the read→edit→read rhythm the context
  #    cost is quadratic in.
  #
  # The 5+-tools "consider create_skill" nudge that used to live here is gone
  # outright. It fired on exactly the batched turns we want more of and read as
  # a correction; 5.6% of measured turns issue >1 tool call and none of them
  # should be answered with a suggestion to stop and write a skill.
  defp inject_post_tool_nudges(state, tool_calls) do
    if state.iteration == 1 and
         state.auto_continues < 2 and
         Guardrails.blind_file_write?(tool_calls) do
      Logger.info("[loop] Explore-first nudge: model edited files before reading (iteration 1)")

      nudge = %{
        role: "user",
        content:
          "[System: You edited files you have not read this session. " <>
            "Explore before you act: read the relevant files so your changes match " <>
            "the existing conventions and don't clobber code you haven't seen.]"
      }

      %{state | messages: state.messages ++ [nudge], auto_continues: state.auto_continues + 1}
    else
      state
    end
  end

  # Frozen system prompt cache — avoids rebuilding the system message on every
  # iteration within a single process_message call. Cache key includes plan_mode,
  # session_id, memory version, and channel so it auto-invalidates on any change.
  #
  # ## The hit path used to rebuild everything anyway
  #
  # This read:
  #
  #     {^cache_key, cached} ->
  #       full = Context.build(state)
  #       %{full | messages: [cached | rest]}
  #
  # `Context.build/1` is the expensive call — it resolves the window, picks and
  # fetches the static base, then assembles TWENTY-ONE dynamic blocks against a
  # token budget (world state, git info, workspace overview, tasks, scratchpad,
  # skills, episodic and semantic recall, …). The cached branch paid all of it
  # and then threw the only product away, keeping just the conversation tail it
  # already had in hand. Every ReAct iteration past the first therefore did the
  # full assembly for nothing, and the "cache" reported a hit while doing so —
  # which is the worst failure mode available to a cache, because the cost is
  # hidden rather than removed.
  #
  # `build/1` returns exactly `[system_msg | conversation]` where `conversation`
  # is `state.messages` verbatim (it applies no trimming of its own — compaction
  # runs earlier, in `TurnPipeline`). So a hit is the concatenation below, and
  # nothing else. `Context.build_count/0` pins this.
  defp cached_context(state) do
    cache_key =
      {state.plan_mode, state.session_id, Process.get(:osa_memory_version, 0), state.channel}

    case Process.get(:osa_system_msg_cache) do
      {^cache_key, cached_system_msg} when cached_system_msg != nil ->
        %{messages: [cached_system_msg | state.messages || []]}

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

  @doc false
  # Test seam for the cache above. Named rather than exposing the private
  # function so the contract under test is "the loop's context for this state",
  # not an implementation detail.
  def context_for_iteration(state), do: cached_context(state)

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

  # Mid-turn steer drain (primitive #32). Destructively pulls any steer
  # directives queued for this session out of the ETS steer queue and appends
  # them to state.messages as system directives. Returns state unchanged when
  # nothing is queued (the common per-step case).
  defp inject_pending_steer(%{session_id: sid} = state) do
    case OptimalSystemAgent.Agent.Loop.Steer.checkout(sid) do
      :empty ->
        state

      {receipt, texts} ->
        if inbox_receipt_delivered?(state.messages, receipt) do
          acknowledge_replayed(
            fn -> OptimalSystemAgent.Agent.Loop.Steer.acknowledge(sid, receipt) end,
            fn -> OptimalSystemAgent.Agent.Loop.Steer.release(sid, receipt) end
          )

          state
        else
          Logger.info(
            "[loop] Mid-turn steer: folded #{length(texts)} directive(s) into session #{sid} at iteration #{state.iteration}"
          )

          Bus.emit(:system_event, %{
            event: :steer_injected,
            session_id: sid,
            iteration: state.iteration,
            count: length(texts)
          })

          injected =
            texts
            |> OptimalSystemAgent.Agent.Loop.Steer.to_messages()
            |> mark_inbox_receipt(receipt)

          next_state = %{
            state
            | messages: state.messages ++ injected
          }

          persist_inbox_delivery(
            state,
            next_state,
            fn -> OptimalSystemAgent.Agent.Loop.Steer.acknowledge(sid, receipt) end,
            fn -> OptimalSystemAgent.Agent.Loop.Steer.release(sid, receipt) end
          )
        end
    end
  end

  # WS6 — background task-notification drain. Runs at the same step boundary
  # as the steer drain: pulls queued <task-notification> payloads for this
  # session and appends them as system messages, so a BUSY turn reacts to
  # background completions on its very next LLM call. Announces the drain on
  # the session topic so the TUI shows why the agent pivots.
  defp inject_pending_task_notifications(%{session_id: sid} = state) do
    case OptimalSystemAgent.Agent.TaskNotifications.checkout(sid) do
      :empty ->
        state

      {receipt, notifs} ->
        if inbox_receipt_delivered?(state.messages, receipt) do
          acknowledge_replayed(
            fn ->
              OptimalSystemAgent.Agent.TaskNotifications.acknowledge(sid, receipt, notifs)
            end,
            fn -> OptimalSystemAgent.Agent.TaskNotifications.release(sid, receipt) end
          )

          state
        else
          Logger.info(
            "[loop] Task notifications: folded #{length(notifs)} into session #{sid} at iteration #{state.iteration}"
          )

          Bus.emit(:system_event, %{
            event: :task_notification_injected,
            session_id: sid,
            iteration: state.iteration,
            count: length(notifs)
          })

          OptimalSystemAgent.Agent.TaskNotifications.announce(sid, notifs)

          injected =
            notifs
            |> OptimalSystemAgent.Agent.TaskNotifications.to_messages()
            |> mark_inbox_receipt(receipt)

          next_state = %{
            state
            | messages: state.messages ++ injected
          }

          persist_inbox_delivery(
            state,
            next_state,
            fn ->
              OptimalSystemAgent.Agent.TaskNotifications.acknowledge(sid, receipt, notifs)
            end,
            fn -> OptimalSystemAgent.Agent.TaskNotifications.release(sid, receipt) end
          )
        end
    end
  end

  defp mark_inbox_receipt(messages, receipt),
    do: Enum.map(messages, &Map.put(&1, :durable_inbox_ids, receipt))

  defp inbox_receipt_delivered?(messages, receipt) do
    delivered =
      messages
      |> Enum.flat_map(&(&1[:durable_inbox_ids] || &1["durable_inbox_ids"] || []))
      |> MapSet.new()

    Enum.all?(receipt, &MapSet.member?(delivered, &1))
  end

  defp acknowledge_replayed(acknowledge, release) do
    case acknowledge.() do
      :ok -> :ok
      {:error, _reason} -> release.()
    end
  end

  defp persist_inbox_delivery(previous_state, next_state, acknowledge, release) do
    case OptimalSystemAgent.Agent.SessionPersistence.save(
           next_state.session_id,
           next_state.messages,
           next_state.working_dir
         ) do
      :ok ->
        case acknowledge.() do
          :ok ->
            next_state

          {:error, reason} ->
            release.()
            Logger.error("[loop] durable inbox acknowledgement failed: #{inspect(reason)}")
            next_state
        end

      {:error, reason} ->
        release.()
        Logger.error("[loop] durable inbox delivery failed: #{inspect(reason)}")
        previous_state
    end
  end

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

    # Only nag when GENUINELY near the ceiling — not every iteration. The old
    # guard `remaining <= max_iter` was a tautology (remaining is always < max_iter
    # once iteration > 0), so a budget message was appended on EVERY iteration,
    # inflating context and pushing the model to "wrap up" thousands of turns early.
    budget_warn_threshold = 10

    if state.iteration > 0 and remaining <= budget_warn_threshold do
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
