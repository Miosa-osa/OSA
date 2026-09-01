defmodule OptimalSystemAgent.Agent.Loop.Telemetry do
  @moduledoc """
  Context pressure and token estimation telemetry for the agent loop.

  Emits `context_pressure` events to the Events.Bus and Phoenix.PubSub so the
  TUI status bar can display live context window utilization.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Events.Bus

  @doc """
  Emit context window pressure metrics for the current state.

  Uses actual LLM-reported input tokens when available; falls back to the
  word-count heuristic from `Compactor.estimate_tokens/1`.
  """
  @spec emit_context_pressure(map()) :: :ok
  def emit_context_pressure(state) do
    # Provider-aware window: for local providers (Ollama/LM Studio/llama.cpp) the
    # usable window is min(config num_ctx, trained window), not the catalog's
    # trained size. `effective_context_window/2` resolves that; for hosted
    # providers it is identical to the trained `context_window/1`.
    model_window = provider_context_window(state)

    # ONE denominator. `used_percent/2` and `warning_state/2` both clamp the
    # window internally (`operative_window/1`, min(window, 200k)), but the raw
    # window was ALSO emitted as `max_tokens` — which the TUI both displays and
    # uses as its own ratio fallback (`estimated_tokens / max_tokens`). On a
    # 500K model that is a 2.8x disagreement inside a single status line.
    #
    # REPORTED LIVE on grok-4.6 (500K window) at ~104.6k occupancy:
    #
    #     104_600 / 500_000              = 21%   ("it dropped to 20%")
    #     104_600 / 180_000 (operative)  = 58%   ("then to like 50%")
    #
    # Same session, same instant, two readings — which is exactly what the
    # numbers "moving in ways they cannot interpret" was. So `max_tokens` is now
    # the window OSA actually operates in, the one every threshold is derived
    # from, and the model's true window is reported alongside it under its own
    # name rather than silently standing in for it.
    max_tok =
      if model_window > 0,
        do: CompactionThresholds.operative_window(model_window),
        else: 0

    # Actual current usage: prefer the provider-reported input tokens; when the
    # provider does not return usage (glm/Ollama) fall back to the char/word
    # estimate so the meter reflects real occupancy instead of sticking at 0.
    estimated =
      if state.last_input_tokens > 0,
        do: state.last_input_tokens,
        else: OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)

    # Percent is measured against the EFFECTIVE window (window - output reserve),
    # Claude Code parity, so "N% used" lines up with the auto-compact threshold.
    utilization =
      if max_tok > 0,
        do: CompactionThresholds.used_percent(estimated, max_tok),
        else: 0.0

    warning =
      if is_integer(max_tok) and max_tok > 0 do
        CompactionThresholds.warning_state(estimated, max_tok)
      else
        %{percent_left: 100, above_warning: false, above_compact: false, at_blocking_limit: false}
      end

    # The two ABSOLUTE thresholds the warning above was derived from, so the TUI
    # can re-derive it instead of caching it.
    #
    # `utilization`/`percent_left`/`context_low` are three renderings of one
    # fact, but only the first has a second writer on the TUI side: the status
    # bar self-heals its ratio from `LlmResponse.input_tokens`
    # (`StatusBar::note_input_tokens`) because this event does not fire on every
    # provider/turn. The banner had no such path, so the two drifted apart —
    # REPORTED LIVE, one frame, immediately after a compaction:
    #
    #     Context low (6% remaining)      ← this event, pre-compaction
    #     ⣿⢿░░░░░░ 15% ctx                ← self-healed from the next request
    #
    # Shipping the thresholds lets the TUI compute the banner from whatever
    # total it currently holds, which makes the contradiction unrepresentable
    # rather than merely fixed on this path.
    {compact_at, warn_at} =
      if is_integer(max_tok) and max_tok > 0 do
        {CompactionThresholds.compact_at(max_tok), CompactionThresholds.warn_at(max_tok)}
      else
        {0, 0}
      end

    # Every threshold decision, above `debug`, with the denominator named. The
    # old line reported `max` alone, which was ambiguous between the model's
    # window and the operative one and so could not be used to tell whether a
    # missing compaction was "not yet due" or "never going to fire".
    Logger.info(
      "[ctx] estimated=#{estimated} operative_window=#{max_tok} " <>
        "model_window=#{model_window}#{if max_tok < model_window, do: " (clamped)", else: ""} " <>
        "util=#{utilization}% left=#{warning.percent_left}% " <>
        "warn_at=#{if max_tok > 0, do: CompactionThresholds.warn_at(max_tok), else: 0} " <>
        "compact_at=#{if max_tok > 0, do: CompactionThresholds.compact_at(max_tok), else: 0} " <>
        "above_warning=#{warning.above_warning} above_compact=#{warning.above_compact}"
    )

    # Mirror this session's LIVE context utilization into the per-agent control
    # store. A subagent's session_id IS its agent_id (Orchestrator), so the
    # progress forwarder can read it back and surface a real "N% ctx" on the
    # agent-dashboard row instead of a cumulative, cache-inclusive token count
    # that reads like runaway spend. Best-effort — a telemetry write must never
    # break the turn.
    _ =
      try do
        OptimalSystemAgent.Agent.ExecutionControl.progress(
          state.session_id,
          # Integer percent 0..100. The TUI decodes this as Option<u32>; a float
          # would fail that decode and drop the whole progress frame, so round.
          %{context_percent: round(utilization * 1.0)}
        )
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end

    Bus.emit(:system_event, %{
      event: :context_pressure,
      session_id: state.session_id,
      estimated_tokens: estimated,
      max_tokens: max_tok,
      model_context_window: model_window,
      context_window_clamped: max_tok < model_window,
      utilization: utilization,
      percent_left: warning.percent_left,
      context_low: warning.above_warning,
      above_compact: warning.above_compact,
      at_blocking_limit: warning.at_blocking_limit,
      compact_at: compact_at,
      warn_at: warn_at
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :context_pressure,
         # `event` mirrors the system_event sub-event convention so the TUI's
         # parse_system_event/1 (which keys on the `event` field) accepts this
         # frame. Without it the Rust SSE parser drops the frame and the context
         # meter stays at 0%. The SSE header stays "context_pressure" because
         # `type` is not :system_event (see AgentRoutes.sse_loop/2).
         event: :context_pressure,
         session_id: state.session_id,
         estimated_tokens: estimated,
         max_tokens: max_tok,
         model_context_window: model_window,
         context_window_clamped: max_tok < model_window,
         utilization: utilization,
         percent_left: warning.percent_left,
         context_low: warning.above_warning,
         above_compact: warning.above_compact,
         at_blocking_limit: warning.at_blocking_limit,
         compact_at: compact_at,
         warn_at: warn_at
       }}
    )

    :ok
  rescue
    e -> Logger.debug("emit_context_pressure failed: #{inspect(e)}")
  end

  # Resolve the usable context window for the state's model + provider. Falls
  # back to the trained window (and 0 on total failure) so a provider lookup
  # miss never crashes the telemetry path.
  @spec provider_context_window(map()) :: non_neg_integer()
  defp provider_context_window(state) do
    alias OptimalSystemAgent.Providers.Registry

    model = Map.get(state, :model)
    provider = normalize_provider(Map.get(state, :provider))

    cond do
      is_nil(model) ->
        0

      # 0 means "unknown" to consumers, which render tokens without a percentage.
      # Never fall back to the lossy default here: this feeds the LIVE context bar,
      # and a percentage against a fabricated denominator is worse than none.
      is_nil(provider) ->
        case Registry.context_window_info(model) do
          {:ok, cw} when is_integer(cw) and cw > 0 -> cw
          _ -> 0
        end

      true ->
        case Registry.effective_context_window_info(model, provider) do
          {:ok, cw} when is_integer(cw) and cw > 0 -> cw
          _ -> 0
        end
    end
  rescue
    _ -> 0
  end

  defp normalize_provider(p) when is_atom(p) and not is_nil(p), do: p

  defp normalize_provider(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp normalize_provider(_), do: nil

  @doc """
  Estimate token count for session introspection (`:get_state` response).
  Returns 0 on any error.
  """
  @spec estimate_tokens(map()) :: non_neg_integer()
  def estimate_tokens(state) do
    try do
      OptimalSystemAgent.Agent.Compactor.estimate_tokens(state.messages)
    rescue
      _ -> 0
    end
  end

  @doc """
  Extract unique tool names used in the message history (whole-session scope).
  """
  @spec extract_tools_used(list(map())) :: list(String.t())
  def extract_tools_used(messages) do
    messages
    |> extract_tool_call_names()
    |> Enum.uniq()
  end

  @doc """
  Tool names called in messages appended after index `since` — per-TURN scope.

  NOT deduplicated: one entry per call, so the turn recap counts tool USES
  (Claude Code's `toolUseCount` semantics — "5 reads + 3 bash" is 8, not 2),
  never distinct tool types, and never tools from earlier turns (the message
  list accumulates across the whole session).
  """
  @spec tools_used_since(list(map()), non_neg_integer()) :: list(String.t())
  def tools_used_since(messages, since) when is_integer(since) and since >= 0 do
    messages
    |> Enum.drop(since)
    |> extract_tool_call_names()
  end

  # Internal bookkeeping tools that auto-fire (memory persistence/recall,
  # session history search). They must not, on their own, make a trivial turn
  # print a "✻ Worked for Ns · 1 tool use" recap. The TUI keeps a mirror filter
  # (util.rs is_internal_tool) as defense-in-depth for legacy payloads.
  @internal_tools ~w(session_search session_recall recall)
  @internal_tool_prefixes ~w(memory)

  @doc "True for internal bookkeeping tools excluded from the turn recap."
  @spec internal_tool?(term()) :: boolean()
  def internal_tool?(name) when is_binary(name) do
    n = name |> String.trim() |> String.downcase()
    n in @internal_tools or Enum.any?(@internal_tool_prefixes, &String.starts_with?(n, &1))
  end

  def internal_tool?(_), do: false

  @doc "Drop internal bookkeeping tools, keeping substantive user-visible work."
  @spec substantive_tools(list(String.t())) :: list(String.t())
  def substantive_tools(names), do: Enum.reject(names, &internal_tool?/1)

  defp extract_tool_call_names(messages) do
    messages
    |> Enum.filter(fn
      %{role: "assistant", tool_calls: tcs} when is_list(tcs) and tcs != [] -> true
      _ -> false
    end)
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.map(& &1.name)
  end
end
