defmodule OptimalSystemAgent.CLI.Headless.Stream do
  @moduledoc """
  Turns one session's live events into `osa run --format stream-json` events.

  Pure: `handle/2` takes the translator state and one message from the
  session's PubSub topics (`"osa:session:<id>"` and `Agent.ToolStream`'s
  topic) and returns the events to write plus the next state. The runner owns
  the IO, so the schema is testable message by message.

  ## Event schema (one JSON object per line, every event has `session_id`)

      {"type":"system","subtype":"init", "cwd", "model", "provider",
       "permission_mode", "tools":[...], "mcp_servers":[{"name","status"}],
       "resumed", "history_messages", "osa_version"}
      {"type":"token","delta":"..."}                  streamed answer text
      {"type":"thinking","delta":"..."}               streamed reasoning
      {"type":"assistant","message":{"role":"assistant",
         "content":[{"type":"text","text":"..."}]}}   one per model message
      {"type":"tool_use","id","name","input":{...}}
      {"type":"tool_result","tool_use_id","name","content","is_error","truncated"}
      {"type":"usage","usage":{"input_tokens","output_tokens",
         "cache_creation_tokens","cache_read_tokens"},"duration_ms"}
      {"type":"compaction_start","trigger","tokens_before"}
      {"type":"compaction_end","success":true,"tokens_before","tokens_after",
         "messages_before","messages_after","duration_ms"}
      {"type":"compaction_end","success":false,"error","duration_ms"}
      {"type":"result","subtype":"success"|"error_during_execution",
       "is_error", "result", "content", ...}           last event of a turn

  The `result` event is built by the runner (it owns timing and spend); see
  `CLI.Headless`.
  """

  @type t :: %{
          session_id: String.t(),
          message_id: term(),
          buffer: iodata(),
          assistant_messages: non_neg_integer(),
          context: map() | nil,
          compactions: non_neg_integer(),
          turn_error: map() | nil
        }

  @doc "Fresh translator state for one turn."
  @spec new(String.t(), map() | nil) :: t()
  def new(session_id, context \\ nil) do
    %{
      session_id: session_id,
      message_id: nil,
      buffer: [],
      assistant_messages: 0,
      context: context,
      compactions: 0,
      turn_error: nil
    }
  end

  @doc "Translate one message. Returns `{events, state}`."
  @spec handle(t(), term()) :: {[map()], t()}
  def handle(state, {:osa_event, %{} = event}), do: event(state, event)

  def handle(state, {:osa_tool_stream, :use, %{} = call}) do
    {flushed, state} = flush(state)

    use = %{
      type: "tool_use",
      id: call[:id],
      name: call[:name],
      input: call[:input] || %{}
    }

    {flushed ++ [stamp(use, state)], state}
  end

  def handle(state, {:osa_tool_stream, :result, %{} = result}) do
    event = %{
      type: "tool_result",
      tool_use_id: result[:id],
      name: result[:name],
      content: result[:content] || "",
      is_error: result[:is_error] == true,
      truncated: result[:truncated] == true
    }

    {[stamp(event, state)], state}
  end

  def handle(state, _other), do: {[], state}

  @doc """
  End of turn: flush any streamed text as an `assistant` message. When the
  provider streamed nothing at all (a non-streaming provider), the final answer
  becomes the turn's single `assistant` message, so a consumer that reads only
  `assistant` events still sees it.
  """
  @spec finish(t(), String.t() | nil) :: {[map()], t()}
  def finish(state, final_text) do
    {flushed, state} = flush(state)

    if state.assistant_messages == 0 and is_binary(final_text) and final_text != "" do
      {flushed ++ [assistant(final_text, state)],
       %{state | assistant_messages: state.assistant_messages + 1}}
    else
      {flushed, state}
    end
  end

  # ── Session-topic events ──────────────────────────────────────────────

  defp event(state, %{type: :streaming_token} = ev) do
    text = ev[:text] || ""
    id = ev[:message_id]

    # A new message id means the model started a new message: whatever was
    # streamed under the previous id is complete.
    {flushed, state} =
      if state.message_id != nil and id != state.message_id, do: flush(state), else: {[], state}

    state = %{state | message_id: id, buffer: [state.buffer, text]}

    if text == "" do
      {flushed, state}
    else
      {flushed ++ [stamp(%{type: "token", delta: text}, state)], state}
    end
  end

  defp event(state, %{type: :thinking_delta} = ev) do
    case ev[:text] do
      text when is_binary(text) and text != "" ->
        {[stamp(%{type: "thinking", delta: text}, state)], state}

      _ ->
        {[], state}
    end
  end

  # The loop bridges usage twice: once from the stream terminator (that frame
  # carries `cache_status`) and once per completed round-trip. Only the
  # round-trip frame is reported, so a consumer that sums `usage` events does
  # not double count.
  defp event(state, %{type: :llm_response, usage: %{} = usage} = ev) do
    if Map.has_key?(ev, :cache_status) or map_size(usage) == 0 do
      {[], state}
    else
      usage_event = %{
        type: "usage",
        duration_ms: ev[:duration_ms],
        usage: %{
          input_tokens: usage[:input_tokens] || 0,
          output_tokens: usage[:output_tokens] || 0,
          cache_creation_tokens: usage[:cache_creation_input_tokens] || 0,
          cache_read_tokens: usage[:cache_read_input_tokens] || 0
        }
      }

      {[stamp(usage_event, state)], state}
    end
  end

  # The loop answers `{:ok, text}` even when the turn died on a provider
  # failure (the TUI shows the error as text); `turn_error` on the final
  # `agent_response` is what says it was not an answer.
  defp event(state, %{type: :agent_response} = ev) do
    case ev[:turn_error] do
      %{} = error -> {[], %{state | turn_error: error}}
      _ -> {[], state}
    end
  end

  defp event(state, %{type: :context_pressure} = ev) do
    {[], %{state | context: context_from_pressure(ev)}}
  end

  defp event(state, %{type: :system_event, event: :compaction_started} = ev) do
    start = %{
      type: "compaction_start",
      trigger: to_string(ev[:trigger] || "auto"),
      tokens_before: ev[:tokens_before]
    }

    {[stamp(start, state)], state}
  end

  defp event(state, %{type: :system_event, event: :compaction_completed} = ev) do
    done = %{
      type: "compaction_end",
      success: true,
      tokens_before: ev[:tokens_before],
      tokens_after: ev[:tokens_after],
      messages_before: ev[:messages_before],
      messages_after: ev[:messages_after],
      duration_ms: ev[:duration_ms]
    }

    {[stamp(done, state)], %{state | compactions: state.compactions + 1}}
  end

  defp event(state, %{type: :system_event, event: :compaction_failed} = ev) do
    failed = %{
      type: "compaction_end",
      success: false,
      error: to_string(ev[:reason] || "compaction failed"),
      duration_ms: ev[:duration_ms]
    }

    {[stamp(failed, state)], state}
  end

  defp event(state, _event), do: {[], state}

  @doc """
  The `context` block of a `result` event from a `context_pressure` frame:
  tokens in use against the model's window, and where auto-compaction fires.
  """
  @spec context_from_pressure(map()) :: map()
  def context_from_pressure(ev) do
    window = ev[:max_tokens] || ev[:model_context_window]
    used = ev[:estimated_tokens]

    %{
      used_tokens: used,
      window_tokens: window,
      percent: ev[:utilization] || percent(used, window),
      compact_at_tokens: ev[:compact_at]
    }
  end

  @doc false
  def percent(used, window)
      when is_integer(used) and is_integer(window) and window > 0,
      do: Float.round(used / window * 100, 1)

  def percent(_used, _window), do: nil

  # ── Helpers ───────────────────────────────────────────────────────────

  defp flush(%{buffer: buffer} = state) do
    text = IO.iodata_to_binary(buffer)
    state = %{state | buffer: []}

    if String.trim(text) == "" do
      {[], state}
    else
      {[assistant(text, state)], %{state | assistant_messages: state.assistant_messages + 1}}
    end
  end

  defp assistant(text, state) do
    stamp(
      %{
        type: "assistant",
        message: %{role: "assistant", content: [%{type: "text", text: text}]}
      },
      state
    )
  end

  defp stamp(event, %{session_id: sid}), do: Map.put(event, :session_id, sid)
end
