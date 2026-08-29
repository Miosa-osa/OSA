defmodule OptimalSystemAgent.Agent.Loop.LLMClient do
  @moduledoc """
  LLM call abstraction for the agent loop.

  Wraps Providers.chat and Providers.chat_stream with per-session
  provider/model routing, streaming callback setup, thinking config,
  and idle-timeout detection (kills connections that go silent).
  """
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Providers.Resilience
  alias OptimalSystemAgent.Agent.Trajectory
  alias OptimalSystemAgent.Utils.Mojibake

  # If no streaming token arrives for this long, the connection is treated as
  # dead. NOT a total-duration cap — an active stream can run indefinitely; the
  # watchdog resets on EVERY streamed event, so any real progress keeps it open.
  #
  # 5 minutes, matching Codex's `stream_idle_timeout_ms = 300_000`. This was
  # briefly raised to 30 minutes on the reasoning that a loaded provider can go
  # quiet while healthy — but 30 minutes does not distinguish a healthy-but-slow
  # provider from a wedged one; it just lets a token-trickle keep-alive (a socket
  # that dribbles a byte occasionally while making no real progress) hang the
  # turn for the whole window before the watchdog notices. Five minutes of TRUE
  # silence is strong evidence of a dead connection, and a genuinely long tool
  # call still streams *something* well inside it. A provider that knows it needs
  # a tighter bound passes a shorter `:idle_timeout` per request, which wins.
  @default_idle_timeout_ms 300_000

  # Tighter idle window for CLOUD REASONING models (the Ollama Cloud family, e.g.
  # the default `glm-5.2:cloud`). These emit all their reasoning on the thinking
  # channel and then the server can PAUSE before the first content token; that
  # post-reasoning silence is a real gap, not a slow-but-healthy trickle, so the
  # full 5-minute default makes the turn look wedged for far too long. Thinking
  # tokens reset the watchdog, so only a TRUE gap counts, and 2 minutes of it on
  # a hosted model is strong evidence of a stall. RETRYABLE like the default (the
  # watchdog fire arm is unchanged), so a trip recovers the turn on its own much
  # sooner. A local model keeps the full 5 minutes (cold-load first token), and
  # an explicit per-request `:idle_timeout` still wins.
  @cloud_reasoning_idle_timeout_ms 120_000

  defp idle_timeout_ms do
    Application.get_env(
      :optimal_system_agent,
      :llm_stream_idle_timeout_ms,
      @default_idle_timeout_ms
    )
  end

  # The idle window for THIS request. An explicit per-request `:idle_timeout`
  # always wins; otherwise a cloud reasoning model (detected by the same
  # `:cloud`/`-cloud` tag convention `Registry.provider_for_model/1` uses) gets
  # the tighter `@cloud_reasoning_idle_timeout_ms`, floored against any lower
  # configured default. Every other request keeps the configured default.
  defp request_idle_timeout_ms(opts, model) do
    case Keyword.fetch(opts, :idle_timeout) do
      {:ok, explicit} ->
        explicit

      :error ->
        if OptimalSystemAgent.Providers.OllamaCloud.cloud_tag?(model) do
          min(idle_timeout_ms(), @cloud_reasoning_idle_timeout_ms)
        else
          idle_timeout_ms()
        end
    end
  end

  # Process-dictionary key holding the id of the assistant message currently
  # being generated. See `mint_message_id/1`.
  @message_id_key :osa_stream_message_id

  # Process-dictionary flag: the open assistant segment has ended, so the next
  # generation must mint a NEW id rather than continue the current one. See
  # `start_new_message_segment/0`.
  @new_segment_key :osa_stream_new_segment

  # Hard ceiling on a server-directed `Retry-After` pause taken in THIS module.
  #
  # `Providers.Resilience.backoff_ms/2` caps its own honouring of the header at
  # 60s; the fallback-chain path below took whatever number came back and slept
  # for it verbatim, with no bound of its own. Today that number happens to be
  # pre-capped by `Providers.RetryClassifier`, so the reachable path is bounded
  # — but only incidentally, by a collaborator. A `Process.sleep/1` that parks
  # an unattended agent for an attacker-chosen duration must not depend on
  # somebody else's constant staying where it is: the bound belongs at the
  # sleep. Same value as Resilience's so the two paths agree.
  @retry_after_cap_ms 60_000

  @doc """
  Clamp a server-supplied `Retry-After` delay (ms) to `#{@retry_after_cap_ms}ms`.

  `nil` / non-positive / non-integer all collapse to `0` (no wait). Public +
  `@doc false` purely as a test seam for the cap.
  """
  @spec capped_retry_delay_ms(term()) :: non_neg_integer()
  def capped_retry_delay_ms(ms) when is_integer(ms) and ms > 0,
    do: min(ms, retry_after_cap_ms())

  def capped_retry_delay_ms(_), do: 0


  # Map the session's speed priority to an OpenAI processing tier. Only OpenAI
  # honours `service_tier`; openai_compat gates it to that provider, so setting
  # it for any provider is safe (ignored elsewhere). :loose → "flex" (~50%
  # cheaper, slower — right for long-horizon background work); :immediate →
  # "priority" (faster); :standard / unknown → unset (provider default).
  defp maybe_put_service_tier(opts, state) do
    case service_tier_for(state) do
      nil -> opts
      tier -> Keyword.put_new(opts, :service_tier, tier)
    end
  end

  defp service_tier_for(state) when is_map(state) do
    case Map.get(state, :priority) do
      :loose -> "flex"
      :immediate -> "priority"
      _ -> nil
    end
  end

  defp service_tier_for(_), do: nil


  defp retry_after_cap_ms do
    case Application.get_env(:optimal_system_agent, :retry_after_cap_ms, @retry_after_cap_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @retry_after_cap_ms
    end
  end

  @doc """
  Identity of the assistant message currently being generated in THIS process.

  `message_id` is to assistant text what `tool_call_id` is to tool calls — the
  backend's stable per-message identity. It rides every `streaming_token` and
  the terminal `agent_response` so the client can tell "more of the same
  message" from "a new message", and can recognise a repeated finalization.

  ## A message is a SEGMENT, not a generation

  This id used to be minted on every provider call, on the reading that "every
  generation is a distinct assistant message". One turn runs several
  generations back to back with no tool call between them — the verification
  gate, an output-token target, a just-crossed compaction boundary, a stop hook
  forcing continuation — and each re-entry into `ReactLoop.run/1` minted a new
  id.

  The client is right to trust the id: a new id means a new message, so it
  closes the current block and opens another. Minting per generation therefore
  tore ONE answer into two `◈ OSA` blocks, split wherever the continuation
  happened to land — mid-thought, and permanently, because a committed block
  goes to the terminal's native scrollback and cannot be re-joined.

  What the user perceives as one message is a SEGMENT: an uninterrupted run of
  assistant text. It ends when something genuinely separates it on screen —
  a tool call (whose cell is drawn between the two halves), or a new user turn.
  It does NOT end because the loop decided to ask the model to keep going.

  So the id is minted on the first generation of a segment and REUSED by every
  continuation, and `start_new_message_segment/0` is what arms the next mint.

  Returns `nil` when no generation has run in this process this turn (a genre
  reply, a canned error frame) — clients must treat that as "no id" and fall
  back to their legacy behaviour, never as a matching id.
  """
  @spec current_message_id() :: String.t() | nil
  def current_message_id, do: Process.get(@message_id_key)

  @doc """
  Drop the current message id. Called at turn start so a turn that performs no
  LLM generation at all cannot inherit the previous turn's id — which the
  client would read as a repeat of an already-finalized message and discard.
  """
  @spec reset_message_id() :: :ok
  def reset_message_id do
    Process.delete(@message_id_key)
    Process.delete(@new_segment_key)
    :ok
  end

  @doc """
  End the current assistant segment: the NEXT generation in this process mints
  a fresh `message_id` instead of continuing the current one.

  Called from `ReactLoop.continue_after_tools/4` — tool results have just been
  folded into the conversation, so the client will draw a tool cell between the
  text before it and the text after it. Those two really are separate blocks.

  Deliberately does NOT clear `current_message_id/0`. The turn-final
  `agent_response` (`Loop.run_and_reply/2`) stamps whatever id is current, and
  a tool run that turns out to be the last thing in the turn must still
  finalize the segment it belongs to rather than send `nil` and drop the client
  back to its id-less legacy path.
  """
  @spec start_new_message_segment() :: :ok
  def start_new_message_segment do
    Process.put(@new_segment_key, true)
    :ok
  end

  # The id for the generation about to run: a fresh one when no segment is open
  # or one was explicitly ended, otherwise the open segment's id continued.
  defp ensure_message_id(session_id) do
    case {Process.get(@message_id_key), Process.get(@new_segment_key)} do
      {id, nil} when is_binary(id) -> id
      _ -> mint_message_id(session_id)
    end
  end

  # Mint + publish the id for a new segment. Monotonic, session-scoped, and
  # only ever compared for equality by clients.
  defp mint_message_id(session_id) do
    id = "#{session_id}-m#{:erlang.unique_integer([:positive, :monotonic])}"
    Process.put(@message_id_key, id)
    Process.delete(@new_segment_key)
    id
  end

  # Emit one repaired, non-empty text delta to every consumer: the retry
  # one-way-door, the partial-recovery buffer, the local event bus, and the
  # PubSub bridge the TUI reads. Factored out of the `:text_delta` callback arm
  # so the arm can skip it when the stateful mojibake repair held the whole
  # delta back as an incomplete sequence.
  defp emit_text_delta(text, session_id, message_id, heartbeat) do
    _ = heartbeat

    # One-way door: this byte is about to be on the user's screen. Past this
    # point a same-provider retry would re-emit it into the SAME live callback
    # and the user would watch the paragraph appear twice, so the retry budget
    # for this request collapses to zero. Runs in the stream task process, which
    # is also the process `Resilience.with_retry/2` is looping in.
    Resilience.mark_output_observed()

    # WS5 — accumulate the partial text (reverse-prepended iodata; single writer
    # = this stream task) so a hard abort can persist what the model had already
    # produced.
    try do
      case :ets.lookup(:osa_stream_partial, session_id) do
        [{^session_id, acc}] when is_list(acc) ->
          :ets.insert(:osa_stream_partial, {session_id, [text | acc]})

        _ ->
          :ets.insert(:osa_stream_partial, {session_id, [text]})
      end
    rescue
      ArgumentError -> :ok
    end

    Bus.emit(:system_event, %{
      event: :streaming_token,
      session_id: session_id,
      message_id: message_id,
      delta: text
    })

    # Bridge to PubSub for SSE delivery to TUI. `message_id` marks which
    # assistant message this delta belongs to — the client starts a fresh buffer
    # when it changes instead of appending onto the superseded one.
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :streaming_token,
         session_id: session_id,
         message_id: message_id,
         text: text
       }}
    )
  end

  # Redact and broadcast one THINKING-channel delta to the local bus and the TUI
  # PubSub bridge. `text` is already mojibake-repaired by the caller (the
  # thinking channel threads its own carry). Kept separate from
  # `emit_text_delta/4` because reasoning rides the thinking channel, not the
  # answer channel, and carries no partial-recovery buffer.
  #
  # Reasoning routinely quotes back the contents of a file the model just read —
  # .env dumps, Authorization headers, key material. It lands in terminal
  # scrollback and in persisted session state, so it gets the same redaction
  # every other user-visible provider text gets.
  defp emit_thinking_delta("", _session_id), do: :ok

  defp emit_thinking_delta(text, session_id) do
    text = Trajectory.redact(text)

    Bus.emit(:system_event, %{
      event: :thinking_delta,
      session_id: session_id,
      delta: text
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, %{type: :thinking_delta, session_id: session_id, text: text}}
    )
  end

  # Grok-style phase-transition signal (borrowed: `Event::PhaseChanged` +
  # `Event::FirstToken`). The spinner already shows THAT the turn is waiting; this
  # names WHY - waiting on the model, streaming reasoning, or writing the answer -
  # so the TUI activity row can label the phase instead of animating a flavor
  # verb. Rides the SAME bus + `osa:session:<id>` PubSub pair every other streamed
  # event uses, so the existing generic SSE forwarder ships it with no new route.
  #
  # Lightweight and additive: one emission per REAL transition, never per token.
  # The `:streaming_reasoning` / `:streaming_text` transitions are guarded once
  # per stream by `emit_phase_once/3` so a torrent of deltas fires each exactly
  # once; `:waiting_for_model` is emitted once at stream start (below), which is
  # already once per call.
  defp emit_phase(phase, session_id) do
    Bus.emit(:system_event, %{
      event: :phase_changed,
      session_id: session_id,
      phase: phase
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, %{type: :phase_changed, session_id: session_id, phase: phase}}
    )
  end

  # Emit `phase` exactly once per stream: fire only when this session's guard flag
  # is unset, then set it. The flag lives in the stream-task process dictionary
  # (keyed by session, exactly like the mojibake carries) and is cleared at stream
  # start AND in the `:done` arm - the same belt-and-suspenders reset the carries
  # get - so a reused task process starts each stream's phase machine clean.
  defp emit_phase_once(phase, session_id, flag_key) do
    case Process.get({flag_key, session_id}) do
      true ->
        :ok

      _ ->
        Process.put({flag_key, session_id}, true)
        emit_phase(phase, session_id)
    end
  end

  # Clear this stream's phase guards. Mirrors the moji-carry deletes so the
  # once-per-stream transitions cannot leak across streams sharing a task process.
  defp reset_phase_flags(session_id) do
    Process.delete({:osa_phase_reasoning_sent, session_id})
    Process.delete({:osa_phase_text_sent, session_id})
  end

  @doc """
  Synchronous LLM chat — routes through the configured provider/model for this session.
  """
  def llm_chat(%{provider: provider, model: model} = state, messages, opts) do
    Logger.debug(
      "[llm] chat — #{length(messages)} messages (sanitized): #{inspect(sanitize_for_log(messages))}"
    )

    # A non-streaming round-trip carries an id too, so the terminal
    # `agent_response` always names the segment it finalizes. Continues the open
    # segment; mints only when none is open or one was just ended by a tool run.
    _ = ensure_message_id(Map.get(state, :session_id, "session"))

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts
    opts = maybe_put_service_tier(opts, state)

    # Session identity for the provider layer: it keys the prompt-cache
    # attributor's per-scope comparison, and on OpenAI it becomes the
    # `prompt_cache_key` sent to the server. Stable for the whole thread —
    # never regenerated per request.
    opts = maybe_put_session(opts, Map.get(state, :session_id))

    # TEMP measurement instrumentation (OSA_CONTEXT_TRACE=1). No-op when unset.
    OptimalSystemAgent.Agent.Loop.ContextTrace.dump(
      Map.get(state, :session_id, "session"),
      messages,
      opts,
      mode: "sync",
      iteration: Map.get(state, :iteration)
    )

    messages
    |> Providers.chat(opts)
    |> surface_sync_reasoning(Map.get(state, :session_id, "session"))
  end

  # A non-streamed turn has no `{:thinking_delta, _}` callback, so a provider
  # that reasons on this path would otherwise hand back `:reasoning` that
  # nothing ever read — the "accumulated somewhere with no reader" shape. Emit
  # it through the SAME bus + PubSub pair the streaming branch ends at, with the
  # same redaction, so the two branches surface reasoning identically and a
  # transcript cannot tell which transport served the turn.
  #
  # The result map is returned UNCHANGED: `:reasoning` stays a separate key and
  # is never folded into `:content`, so it cannot reach the assistant message
  # and be replayed to the provider next turn.
  defp surface_sync_reasoning({:ok, %{reasoning: text} = result}, session_id)
       when is_binary(text) and text != "" do
    text = Trajectory.redact(text)

    Bus.emit(:system_event, %{
      event: :thinking_delta,
      session_id: session_id,
      delta: text
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, %{type: :thinking_delta, session_id: session_id, text: text}}
    )

    {:ok, result}
  end

  defp surface_sync_reasoning(other, _session_id), do: other

  # `Keyword.put_new/3` so an explicit caller-supplied scope (a sub-agent, a
  # side computation with its own prefix) still wins.
  defp maybe_put_session(opts, session_id) when is_binary(session_id) and session_id != "",
    do: Keyword.put_new(opts, :session_id, session_id)

  defp maybe_put_session(opts, _), do: opts

  @doc """
  Streaming LLM chat with idle-timeout detection.

  The stream can run for hours as long as tokens keep arriving. If the
  connection goes silent (no text_delta, thinking_delta, or done event
  for `:llm_stream_idle_timeout_ms`), the call is killed and an error returned.

  Returns {:ok, result} | {:error, reason}.
  """
  def llm_chat_stream(%{session_id: session_id, provider: provider, model: model} = state, messages, opts) do
    Logger.debug(
      "[llm] stream — #{length(messages)} messages (sanitized): #{inspect(sanitize_for_log(messages))} session=#{session_id}"
    )

    # Heartbeat: atomics counter incremented on every streaming event AND on
    # every raw chunk the provider receives from the wire BEFORE it is parsed
    # (the provider bumps this SAME atomic via `opts[:heartbeat]`, injected
    # below). The watchdog checks if the counter has changed since last poll.
    #
    # Grok dual idle-timeout: resetting on raw bytes, not only on parsed events,
    # means a stream that is flowing bytes the parser has not yet turned into an
    # event never false-times-out. The idle timeout then fires only on a TRULY
    # silent pipe (no bytes at all for the window), where the retryable restart
    # is genuinely warranted.
    heartbeat = :atomics.new(1, signed: false)
    :atomics.put(heartbeat, 1, 1)

    # Identity of the assistant SEGMENT this stream contributes to. Resolved
    # HERE, in the Loop process, so the terminal `agent_response` (broadcast
    # later from the same process) stamps the SAME id via `current_message_id/0`.
    # A continuation with no tool call in between keeps the open id, so the
    # client appends to the block the user is already reading instead of opening
    # a second one mid-answer.
    message_id = ensure_message_id(session_id)

    # WS5 — reset this session's partial-text buffer for the new stream so an
    # interrupt persists only THIS stream's text.
    try do
      :ets.insert(:osa_stream_partial, {session_id, []})
    rescue
      ArgumentError -> :ok
    end

    # Start with empty mojibake carries so a prior stream that aborted before
    # its `:done` (leaving a held partial sequence in this reused task process)
    # cannot prepend stale bytes onto this stream's first delta. The thinking
    # channel gets its OWN carry, independent of the answer carry, so a partial
    # sequence held on one channel never bleeds into the other.
    Process.delete({:moji_carry, session_id})
    Process.delete({:moji_think_carry, session_id})

    # Grok phase signal: the request is going out and not one byte has come back
    # yet. Clear this stream's phase guards (mirroring the moji-carry reset above)
    # and announce the wait immediately, so the TUI can label the phase at stream
    # start instead of after its heuristic grace window.
    reset_phase_flags(session_id)
    emit_phase(:waiting_for_model, session_id)

    caller = self()

    callback = fn
      {:text_delta, text} ->
        :atomics.add(heartbeat, 1, 1)
        # First answer-channel delta → the model is writing its reply. Fired on
        # ARRIVAL (once), before the mojibake hold decision below: content is
        # streaming even when a partial byte sequence is held back this chunk.
        emit_phase_once(:streaming_text, session_id, :osa_phase_text_sent)
        # Stateful mojibake repair. Per-delta repair cannot fix a corruption
        # sequence split across two streamed chunks (a delta ending in a lone
        # "â" has nothing to re-decode), which is the common case when a
        # provider streams token-by-token — so we thread a carry buffer through
        # the stream, holding an in-flight partial sequence until it is whole.
        # The carry lives in the process dictionary because this callback runs
        # in the single stream-task process for the whole request; it is flushed
        # in the `:done` arm below.
        {text, moji_carry} =
          Mojibake.repair_stream(Process.get({:moji_carry, session_id}, ""), text)

        Process.put({:moji_carry, session_id}, moji_carry)

        # Everything below emits to the screen/buffer/transcript; skip it when
        # this delta was entirely held back as a possibly-incomplete sequence,
        # so we neither broadcast an empty token nor burn the retry budget on
        # output the user has not actually seen yet.
        if text != "" do
          emit_text_delta(text, session_id, message_id, heartbeat)
        end


      {:done, result} ->
        :atomics.add(heartbeat, 1, 1)
        Logger.debug("[stream] done → session:#{session_id}")

        # Flush whatever the stateful mojibake repair was still holding as a
        # possibly-incomplete sequence, so the live view is not missing the last
        # few characters of the answer. Emitted as one final repaired delta.
        case Process.get({:moji_carry, session_id}, "") do
          "" ->
            :ok

          carry ->
            flushed = Mojibake.flush(carry)
            if flushed != "", do: emit_text_delta(flushed, session_id, message_id, heartbeat)
        end

        Process.delete({:moji_carry, session_id})

        # Same flush for the THINKING channel's independent carry, so the last
        # characters of the reasoning are not lost when the stream ends holding a
        # partial sequence. Emitted as one final thinking delta.
        case Process.get({:moji_think_carry, session_id}, "") do
          "" ->
            :ok

          think_carry ->
            think_carry |> Mojibake.flush() |> emit_thinking_delta(session_id)
        end

        Process.delete({:moji_think_carry, session_id})

        # Clear this stream's phase guards so a reused stream-task process starts
        # the next stream's phase machine clean (mirrors the moji-carry deletes).
        reset_phase_flags(session_id)

        # Repair the FINAL assembled content, not just the live deltas. This is
        # the string that is persisted to the transcript and re-rendered on
        # resume; the deltas above fix the live view, this fixes the copy that
        # outlives the turn. A provider that sends all its content in one final
        # chunk (some cloud models do) is only covered here.
        result =
          case result do
            %{content: content} when is_binary(content) ->
              %{result | content: Mojibake.repair(content)}

            _ ->
              result
          end

        # Broadcast token usage via PubSub for TUI status bar
        # `|| %{}`: a provider that reports `usage: nil` is a present key, so
        # the Map.get/3 default does not fire and the `usage != %{}` guard
        # below would then send nil into Map.get/3 on the next line.
        usage = Map.get(result, :usage) || %{}

        if usage != %{} do
          Phoenix.PubSub.broadcast(
            OptimalSystemAgent.PubSub,
            "osa:session:#{session_id}",
            {:osa_event,
             %{
               type: :llm_response,
               session_id: session_id,
               duration_ms: 0,
               usage: %{
                 input_tokens: Map.get(usage, :input_tokens, 0),
                 output_tokens: Map.get(usage, :output_tokens, 0)
               }
             }}
          )
        end

        send(caller, {:llm_stream_done, result})

      {:thinking_delta, text} ->
        :atomics.add(heartbeat, 1, 1)
        # First reasoning-channel delta → the model is streaming its reasoning.
        # Fired on ARRIVAL (once), before the mojibake hold below, for the same
        # reason as `:streaming_text`.
        emit_phase_once(:streaming_reasoning, session_id, :osa_phase_reasoning_sent)
        # Reasoning is rendered live in the TUI, so it is user-visible output
        # under exactly the same one-way-door rule as `:text_delta`.
        Resilience.mark_output_observed()

        # Stateful mojibake repair for the THINKING channel, threaded through its
        # OWN carry buffer (independent of the answer carry above). A corruption
        # sequence split across two thinking chunks needs the same cross-delta
        # stitching the answer path gets — a per-delta repair leaves a lone
        # trailing `â` unrepairable — so hold the in-flight partial and flush it
        # in the `:done` arm below. Skip the emit when the whole delta was held.
        {text, think_carry} =
          Mojibake.repair_stream(Process.get({:moji_think_carry, session_id}, ""), text)

        Process.put({:moji_think_carry, session_id}, think_carry)

        if text != "", do: emit_thinking_delta(text, session_id)

      {:tool_use_block, tool_call} ->
        # Provider detected a complete tool_use block during streaming.
        # Notify the caller to start executing this tool immediately.
        :atomics.add(heartbeat, 1, 1)
        # Strongest form of the one-way door: the tool is about to RUN. A retry
        # would re-issue it under a fresh id that dedup cannot catch, so the
        # side effect would happen twice. (`classify/1` already refuses to retry
        # a partial carrying tool_calls; this covers the provider that reports
        # the block without folding it into the error partial.)
        Resilience.mark_output_observed()
        send(caller, {:streaming_tool_block, tool_call})

        Bus.emit(:tool_call, %{
          name: tool_call.name,
          phase: :streaming_start,
          args: Map.get(tool_call, :arguments, %{}) |> inspect() |> String.slice(0, 80),
          session_id: session_id
        })

      {:provider_retry, info} ->
        # Bridge provider retries to the session PubSub topic so the SSE loop
        # forwards them and the TUI can render "Retrying in Ns…". The registry
        # forwards this via notify_stream_retry/2 but its own Bus emission has
        # no session_id, so this is the only session-routed path (WS1 item 8).
        :atomics.add(heartbeat, 1, 1)

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{session_id}",
          {:osa_event,
           %{
             type: :provider_retry,
             session_id: session_id,
             attempt: Map.get(info, :attempt, 0),
             max_attempts: Map.get(info, :max_attempts, 0),
             delay_ms: Map.get(info, :delay_ms, 0),
             reason: Map.get(info, :reason, "")
           }}
        )

      _other ->
        :atomics.add(heartbeat, 1, 1)
        :ok
    end

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts
    opts = maybe_put_service_tier(opts, state)
    opts = maybe_put_session(opts, session_id)

    # TEMP measurement instrumentation (OSA_CONTEXT_TRACE=1). No-op when unset.
    OptimalSystemAgent.Agent.Loop.ContextTrace.dump(session_id, messages, opts, mode: "stream")

    # Hand the watchdog atomic to the provider so it can reset the idle timer on
    # EVERY raw chunk it receives (before parsing), not only on the parsed events
    # this module's callback resets it on. Same atomic, same `:atomics.add/3`
    # reset the `:text_delta` arm uses — the provider just calls it from the wire
    # chunk point. A stream with any bytes flowing then never false-times-out.
    opts = Keyword.put(opts, :heartbeat, heartbeat)

    Process.put(:osa_stream_start_time, System.monotonic_time(:millisecond))

    # Run the stream in a linked task so we can kill it on idle timeout.
    # Uses FallbackChain for automatic provider switching on retryable errors.
    caller = self()

    stream_task =
      Task.async(fn ->
        res =
          case Providers.chat_stream(messages, callback, opts) do
            :ok ->
              # Callback-based streaming providers report the response through
              # `callback` and return `:ok` when the stream closes normally.
              # `Providers.chat_stream/3` documents exactly that contract.
              :ok

            {:error, reason} = error ->
              # Try fallback chain on retryable errors
              if OptimalSystemAgent.Providers.FallbackChain.retryable_error?(reason) do
                # Header-aware: honor a server-supplied Retry-After (parsed by
                # RetryClassifier off the original reason) before switching
                # providers, and surface it via the SAME {:provider_retry} UI
                # event the same-provider retry loop uses, so "Retrying in
                # Ns…" reflects the real server-requested wait instead of
                # silently switching providers with no delay at all.
                delay_ms =
                  capped_retry_delay_ms(
                    OptimalSystemAgent.Providers.FallbackChain.retry_delay_ms(reason)
                  )

                Logger.warning(
                  "[llm] Primary provider failed: #{inspect(reason)}, trying fallback chain" <>
                    if(delay_ms > 0, do: " (honoring #{delay_ms}ms retry-after)", else: "")
                )

                if delay_ms > 0 do
                  Phoenix.PubSub.broadcast(
                    OptimalSystemAgent.PubSub,
                    "osa:session:#{session_id}",
                    {:osa_event,
                     %{
                       type: :provider_retry,
                       session_id: session_id,
                       attempt: 1,
                       max_attempts: 1,
                       delay_ms: delay_ms,
                       reason: OptimalSystemAgent.Providers.Resilience.reason_to_string(reason)
                     }}
                  )

                  Process.sleep(delay_ms)
                end

                case OptimalSystemAgent.Providers.FallbackChain.chat_stream_with_fallback(
                       messages,
                       callback,
                       opts
                     ) do
                  {:ok, result, _provider} -> {:ok, result}
                  fallback_error -> fallback_error
                end
              else
                error
              end
          end

        # Always notify the caller of the task's terminal result. On the success
        # path the {:llm_stream_done} message has already been enqueued by the
        # {:done} callback (before chat_stream returns), so the caller consumes
        # that first and treats this message as a no-op. On the failure path
        # where no {:done} callback ever fires (401, unknown provider, every
        # fallback failing), this is the ONLY signal the caller gets — without
        # it the caller would block on the 1h absolute timeout for an instant
        # failure.
        send(caller, {:llm_stream_task_result, res})
        res
      end)

    # Watchdog: polls heartbeat every 10s, kills if no progress for the idle timeout
    idle_timeout = request_idle_timeout_ms(opts, model)

    watchdog =
      spawn_link(fn -> watchdog_loop(heartbeat, stream_task, idle_timeout, session_id) end)

    # WS5 — hard-abort watcher: polls the shared cancel flag every 150ms and
    # pings this caller to kill the in-flight stream the moment the user
    # interrupts — instead of the stream running to the next ReAct iteration
    # boundary. Self-terminates once the stream task is dead.
    _canceller = spawn_link(fn -> cancel_watch_loop(session_id, stream_task, caller) end)

    # Wait for stream completion or idle timeout
    result =
      receive do
        {:llm_stream_done, stream_result} ->
          # Stream completed normally — clean up watchdog
          Process.unlink(watchdog)
          Process.exit(watchdog, :normal)
          # Wait for the task to finish (it should be done already).
          # Use shutdown instead of await — await raises an uncatchable :exit
          # on timeout which crashes the agent loop.
          Task.shutdown(stream_task, 5_000)
          {:ok, stream_result}

        {:llm_stream_cancelled} ->
          # WS5 hard abort: the user interrupted — kill the in-flight provider
          # stream NOW and hand back whatever text already streamed so
          # ReactLoop can persist it under an interrupt marker.
          Logger.info(
            "[stream] User interrupt — killing in-flight stream for session:#{session_id}"
          )

          Process.unlink(watchdog)
          Process.exit(watchdog, :normal)
          Task.shutdown(stream_task, :brutal_kill)
          flush_stream_messages()
          {:cancelled, %{content: partial_text(session_id)}}

        {:llm_idle_timeout, elapsed_ms} ->
          # Watchdog detected idle connection — kill the stream.
          #
          # RETRYABLE, not terminal (Codex parity: the same idle condition is a
          # retryable turn error there). Brutal-killing the task destroys every
          # `Resilience`/`RetryClassifier` retry that was running INSIDE it, so
          # the retry decision has to be re-made one level up — which is why this
          # returns a STRUCTURED reason `{:idle_timeout, %{...}}` instead of a
          # bare string the caller can only render. `ReactLoop.handle_result/3`
          # matches on it to retry the turn.
          #
          # `partial` carries whatever assistant text streamed before the silence
          # so the caller can own the already-executed tool_use ids in a real
          # assistant message when it commits their results to history.
          Logger.warning(
            "[stream] Idle timeout after #{div(elapsed_ms, 1000)}s of silence — killing stream for session:#{session_id}"
          )

          Task.shutdown(stream_task, :brutal_kill)
          # Drop the {:done}/task-result messages a dying stream may already have
          # enqueued so they cannot leak into the Loop mailbox as stale infos.
          flush_stream_messages()

          {:error,
           {:idle_timeout,
            %{
              elapsed_ms: elapsed_ms,
              partial: partial_text(session_id),
              message:
                "LLM stream went silent for #{div(elapsed_ms, 1000)}s — connection likely dropped"
            }}}

        {:llm_stream_task_result, {:error, _} = err} ->
          # The stream task terminated with an error WITHOUT ever firing the
          # {:done} callback (e.g. 401, unknown provider, all fallbacks failed).
          # Fail fast instead of blocking on the 1h absolute timeout.
          Process.unlink(watchdog)
          Process.exit(watchdog, :normal)
          Task.shutdown(stream_task, 5_000)
          err

        {:llm_stream_task_result, {:ok, _}} ->
          # Success terminal result. The {:done} callback already sent
          # {:llm_stream_done} which is handled above; if we somehow observe
          # this first, wait for the stream_done message for the real result.
          receive do
            {:llm_stream_done, stream_result} ->
              Process.unlink(watchdog)
              Process.exit(watchdog, :normal)
              Task.shutdown(stream_task, 5_000)
              {:ok, stream_result}
          after
            5_000 ->
              Process.unlink(watchdog)
              Process.exit(watchdog, :normal)
              Task.shutdown(stream_task, 5_000)
              {:error, "LLM stream completed without a done signal"}
          end
      after
        # Absolute safety net: 1 hour. Should never fire for legitimate work.
        3_600_000 ->
          Logger.error("[stream] Absolute timeout (1h) hit for session:#{session_id}")
          Process.unlink(watchdog)
          Process.exit(watchdog, :normal)
          Task.shutdown(stream_task, :brutal_kill)
          {:error, "LLM stream exceeded 1 hour absolute limit"}
      end

    # WS5 — drain a stale watcher ping that raced the stream's own termination
    # so it can never leak into the Loop process mailbox as an unexpected info.
    receive do
      {:llm_stream_cancelled} -> :ok
    after
      0 -> :ok
    end

    # Record provider telemetry
    stream_duration =
      System.monotonic_time(:millisecond) -
        (Process.get(:osa_stream_start_time) || System.monotonic_time(:millisecond))

    try do
      success = match?({:ok, _}, result)

      OptimalSystemAgent.Telemetry.Metrics.record_provider(
        provider || :unknown,
        stream_duration,
        success
      )

      OptimalSystemAgent.Telemetry.Metrics.record_turn()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    result
  rescue
    e ->
      Logger.error("[stream] Exception in llm_chat_stream: #{inspect(e)}")
      {:error, "Stream error: #{inspect(e)}"}
  end

  # WS5 — cancel watcher: poll the shared cancel-flag table; ping the stream
  # owner the moment the flag appears while the stream is still running.
  defp cancel_watch_loop(session_id, stream_task, owner) do
    Process.sleep(150)

    cancelled? =
      try do
        match?([{^session_id, true}], :ets.lookup(:osa_cancel_flags, session_id))
      rescue
        ArgumentError -> false
      end

    cond do
      not Process.alive?(stream_task.pid) -> :ok
      cancelled? -> send(owner, {:llm_stream_cancelled})
      true -> cancel_watch_loop(session_id, stream_task, owner)
    end
  end

  # Partial streamed text accumulated by the text_delta callback (reverse
  # iodata rows in :osa_stream_partial), joined for interrupt persistence.
  defp partial_text(session_id) do
    case :ets.lookup(:osa_stream_partial, session_id) do
      [{^session_id, acc}] when is_list(acc) ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      _ ->
        ""
    end
  rescue
    ArgumentError -> ""
  end

  # After a hard abort, drop any {:done}/task-result messages the dying stream
  # already enqueued, so they never reach the Loop mailbox as stale infos.
  defp flush_stream_messages do
    receive do
      {:llm_stream_done, _} -> flush_stream_messages()
      {:llm_stream_task_result, _} -> flush_stream_messages()
    after
      0 -> :ok
    end
  end

  # Watchdog process: polls heartbeat counter every 10s.
  # If the counter hasn't changed for `timeout_ms`, sends idle timeout signal.
  defp watchdog_loop(heartbeat, stream_task, timeout_ms, session_id) do
    poll_interval = 10_000
    last_count = :atomics.get(heartbeat, 1)
    watchdog_poll(heartbeat, stream_task, timeout_ms, session_id, poll_interval, last_count, 0)
  end

  defp watchdog_poll(
         heartbeat,
         stream_task,
         timeout_ms,
         session_id,
         poll_interval,
         last_count,
         idle_ms
       ) do
    Process.sleep(poll_interval)

    # Check if stream task is still alive
    unless Process.alive?(stream_task.pid) do
      # Stream finished — watchdog can exit
      :ok
    else
      current_count = :atomics.get(heartbeat, 1)

      if current_count == last_count do
        # No progress — accumulate idle time
        new_idle = idle_ms + poll_interval

        if new_idle >= timeout_ms do
          # Idle timeout exceeded — notify caller
          Logger.warning(
            "[watchdog] No stream activity for #{div(new_idle, 1000)}s — session:#{session_id}"
          )

          send(stream_task.owner, {:llm_idle_timeout, new_idle})
        else
          watchdog_poll(
            heartbeat,
            stream_task,
            timeout_ms,
            session_id,
            poll_interval,
            last_count,
            new_idle
          )
        end
      else
        # Progress detected — reset idle counter
        watchdog_poll(
          heartbeat,
          stream_task,
          timeout_ms,
          session_id,
          poll_interval,
          current_count,
          0
        )
      end
    end
  end

  @doc "Resolve thinking config based on provider, model, effort level, and application config."
  def thinking_config(state) do
    {config, _source} = thinking_decision(state)
    config
  end

  @doc """
  The thinking config for this turn AND the rule that produced it.

  `{config_or_nil, source}` where source is one of `:adaptive`, `:budget`,
  `:model_has_none`, `:disabled_by_config`, `:fast_mode`, `:not_anthropic`.

  Split out from `thinking_config/1` for the same reason
  `Ollama.reasoning_decision/2` was: a capability that can be silently off needs
  something able to state what it is and why. `Observability.current_reasoning/1`
  reads this so `turn_start` / `turn_end` carry it next to `effort`.
  """
  @spec thinking_decision(map()) :: {map() | nil, atom()}
  def thinking_decision(%{provider: provider} = state) do
    alias OptimalSystemAgent.Agent.Effort

    enabled = Application.get_env(:optimal_system_agent, :thinking_enabled, true)

    # Resolve the provider OF THIS REQUEST, then decide.
    #
    # This used to read `provider in [:anthropic, nil] and is_anthropic_provider?()`,
    # and the second conjunct is a global-state read inside a per-request
    # decision: `is_anthropic_provider?/0` asks what the DEFAULT provider is.
    # A user whose default is `:ollama` but who routes a turn to `:anthropic`
    # — a `/model` switch, a fallback-chain hop, a delegate with its own
    # provider — passed the correct `state.provider` check and was still denied
    # thinking, silently, for the whole session.
    #
    # `nil` still consults the default, and must: nil means the caller did not
    # say, so the default provider IS the answer to "which provider is this?".
    # Same rule as `openai_compat.deepseek_endpoint?(nil)` — an unknown does not
    # silently disable a capability, it falls back to what is actually configured.
    resolved_provider = provider || default_provider()

    if enabled and not Effort.fast_mode?() and resolved_provider == :anthropic do
      alias OptimalSystemAgent.Providers.AnthropicModels

      model =
        state.model ||
          Application.get_env(
            :optimal_system_agent,
            :anthropic_model,
            AnthropicModels.default_model()
          )

      # Which thinking dialect the model speaks is a MODEL FACT, not an effort
      # decision. Anthropic removed the fixed thinking budget on the Claude 5
      # family (and Opus 4.7/4.8): sending
      # `{type: "enabled", budget_tokens: N}` to claude-opus-5 / claude-sonnet-5
      # / claude-fable-5 is a hard 400, not a degraded response — so the old
      # "opus gets adaptive, everything else gets a budget" heuristic broke
      # extended thinking outright on every current model except Haiku.
      # Depth on adaptive models is steered by `output_config.effort`
      # (Agent.Effort), not by a token count.
      case AnthropicModels.thinking_mode(model) do
        :adaptive -> {%{type: "adaptive"}, :adaptive}
        :budget -> {%{type: "enabled", budget_tokens: Effort.thinking_budget()}, :budget}
        :none -> {nil, :model_has_none}
      end
    else
      cond do
        resolved_provider != :anthropic -> {nil, :not_anthropic}
        not enabled -> {nil, :disabled_by_config}
        true -> {nil, :fast_mode}
      end
    end
  end

  @doc "The configured default provider — the answer for a request that names none."
  def default_provider do
    Application.get_env(:optimal_system_agent, :default_provider, :ollama)
  end

  @doc """
  Returns true when the configured DEFAULT provider is Anthropic.

  Note this is a question about configuration, not about a request. It must not
  gate a per-request decision — see `thinking_config/1`, where it did.
  """
  def is_anthropic_provider? do
    default_provider() == :anthropic
  end

  @doc "Returns the configured LLM temperature."
  def temperature, do: Application.get_env(:optimal_system_agent, :temperature, 0.7)

  # ── Log sanitization (Bug 17) ─────────────────────────────────────────────
  # Strip system-prompt content from any message list before it touches a
  # Logger call.  The messages are sent to the LLM unchanged — only the copy
  # that appears in log output is redacted.
  #
  # Rules:
  #   - Messages with role "system" (atom or string key) have their content
  #     replaced with the literal string "[REDACTED: system prompt]".
  #   - All other messages are returned as-is.
  #   - Any non-map element is passed through unchanged (defensive).
  @spec sanitize_for_log(list()) :: list()
  defp sanitize_for_log(messages) when is_list(messages) do
    Enum.map(messages, fn
      # Atom-key map with role: "system"
      %{role: "system"} = msg ->
        %{msg | content: "[REDACTED: system prompt]"}

      # String-key map with "role" => "system" (decoded JSON / checkpoint restore)
      %{"role" => "system"} = msg ->
        %{msg | "content" => "[REDACTED: system prompt]"}

      # All other messages — pass through unchanged
      msg ->
        msg
    end)
  end

  defp sanitize_for_log(other), do: other
end
