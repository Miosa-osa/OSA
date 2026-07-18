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

  # If no streaming token arrives for this long, the connection is dead.
  # This is NOT a total-duration cap — active streams can run indefinitely.
  # 300s matches the curl --max-time and port-level timeout in ollama.ex.
  # Large models (nemotron-super) can take 2-3 min to produce the first token
  # on complex multi-tool requests.
  @idle_timeout_ms 300_000

  @doc """
  Synchronous LLM chat — routes through the configured provider/model for this session.
  """
  def llm_chat(%{provider: provider, model: model}, messages, opts) do
    Logger.debug(
      "[llm] chat — #{length(messages)} messages (sanitized): #{inspect(sanitize_for_log(messages))}"
    )

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts
    opts = if model, do: Keyword.put(opts, :model, model), else: opts
    Providers.chat(messages, opts)
  end

  @doc """
  Streaming LLM chat with idle-timeout detection.

  The stream can run for hours as long as tokens keep arriving. If the
  connection goes silent (no text_delta, thinking_delta, or done event
  for #{@idle_timeout_ms}ms), the call is killed and an error returned.

  Returns {:ok, result} | {:error, reason}.
  """
  def llm_chat_stream(%{session_id: session_id, provider: provider, model: model}, messages, opts) do
    Logger.debug(
      "[llm] stream — #{length(messages)} messages (sanitized): #{inspect(sanitize_for_log(messages))} session=#{session_id}"
    )

    # Heartbeat: atomics counter incremented on every streaming event.
    # The watchdog checks if the counter has changed since last poll.
    heartbeat = :atomics.new(1, signed: false)
    :atomics.put(heartbeat, 1, 1)

    # WS5 — reset this session's partial-text buffer for the new stream so an
    # interrupt persists only THIS stream's text.
    try do
      :ets.insert(:osa_stream_partial, {session_id, []})
    rescue
      ArgumentError -> :ok
    end

    caller = self()

    callback = fn
      {:text_delta, text} ->
        :atomics.add(heartbeat, 1, 1)

        # WS5 — accumulate the partial text (reverse-prepended iodata; single
        # writer = this stream task) so a hard abort can persist what the model
        # had already produced.
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
          delta: text
        })

        # Bridge to PubSub for SSE delivery to TUI
        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:session:#{session_id}",
          {:osa_event, %{type: :streaming_token, session_id: session_id, text: text}}
        )

      {:done, result} ->
        :atomics.add(heartbeat, 1, 1)
        Logger.debug("[stream] done → session:#{session_id}")
        # Broadcast token usage via PubSub for TUI status bar
        usage = Map.get(result, :usage, %{})

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

      {:tool_use_block, tool_call} ->
        # Provider detected a complete tool_use block during streaming.
        # Notify the caller to start executing this tool immediately.
        :atomics.add(heartbeat, 1, 1)
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

    Process.put(:osa_stream_start_time, System.monotonic_time(:millisecond))

    # Run the stream in a linked task so we can kill it on idle timeout.
    # Uses FallbackChain for automatic provider switching on retryable errors.
    caller = self()

    stream_task =
      Task.async(fn ->
        res =
          case Providers.chat_stream(messages, callback, opts) do
            {:ok, _} = success ->
              success

            {:error, reason} = error ->
              # Try fallback chain on retryable errors
              if OptimalSystemAgent.Providers.FallbackChain.retryable_error?(reason) do
                Logger.warning(
                  "[llm] Primary provider failed: #{inspect(reason)}, trying fallback chain"
                )

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

    # Watchdog: polls heartbeat every 10s, kills if no progress for @idle_timeout_ms
    idle_timeout = Keyword.get(opts, :idle_timeout, @idle_timeout_ms)

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
          # Watchdog detected idle connection — kill the stream
          Logger.warning(
            "[stream] Idle timeout after #{div(elapsed_ms, 1000)}s of silence — killing stream for session:#{session_id}"
          )

          Task.shutdown(stream_task, :brutal_kill)

          {:error,
           "LLM stream went silent for #{div(elapsed_ms, 1000)}s — connection likely dropped"}

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
  def thinking_config(%{provider: provider} = state) do
    alias OptimalSystemAgent.Agent.Effort

    enabled = Application.get_env(:optimal_system_agent, :thinking_enabled, false)

    if enabled and not Effort.fast_mode?() and provider in [:anthropic, nil] and
         is_anthropic_provider?() do
      model =
        state.model ||
          Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")

      if String.contains?(to_string(model), "opus") do
        %{type: "adaptive"}
      else
        # Use effort level's thinking budget instead of flat config
        budget = Effort.thinking_budget()
        %{type: "enabled", budget_tokens: budget}
      end
    else
      nil
    end
  end

  @doc "Returns true when the configured default provider is Anthropic."
  def is_anthropic_provider? do
    default = Application.get_env(:optimal_system_agent, :default_provider, :ollama)
    default == :anthropic
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
