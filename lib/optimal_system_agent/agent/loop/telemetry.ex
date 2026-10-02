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

    # ONE denominator, and it is the model's REAL window.
    #
    # The meter used to divide by the operative window (the compaction budget,
    # `min(window, ceiling)` = 200k on every >200k model), so a 1M model read
    # as nearly full long before it was. REPORTED LIVE on
    # `deepseek-v4.1-flash:cloud` (1,048,576 window) at 159.3k tokens:
    #
    #     ⣿⣿⣿⣿⣿⣿⢿░ 80% ctx            159,300 / 200,000 (operative)
    #     Context low (4% remaining)   (167,000 - 159,300) / 167,000
    #
    # Both numbers described the compaction budget, and both read as "the
    # model is out of room" on a model with 85% of its window free. The bar
    # now answers "how much of this model's window is in use" (15% there), and
    # the compaction point is a separate, ABSOLUTE number (`compact_at`) the
    # TUI renders in tokens, so the two can no longer be mistaken for one
    # another. Every surface that sets the meter (`/health`, a model switch,
    # `LlmResponse.input_tokens`) already used the real window; this was the
    # one writer that did not, which is also why the bar jumped between two
    # readings mid-session (21% vs 58% on grok-4.6, 80% vs 38% here).
    #
    # The thresholds themselves are unchanged: they are still derived from
    # the operative window, with `model` threaded the same way
    # `ProactiveCompaction.should_compact?/2` threads it, so the warning this
    # event carries and the compaction decision cannot drift apart.
    model = Map.get(state, :model)

    operative =
      if model_window > 0,
        do: CompactionThresholds.operative_window(model_window, model),
        else: 0

    # Actual current usage: prefer the provider-reported input tokens; when the
    # provider does not return usage (glm/Ollama) fall back to the char/word
    # estimate so the meter reflects real occupancy instead of sticking at 0.
    estimated = context_occupancy(state)

    utilization =
      if model_window > 0,
        do: min(100.0, Float.round(estimated / model_window * 100, 1)),
        else: 0.0

    warning =
      if operative > 0 do
        CompactionThresholds.warning_state(estimated, model_window, model)
      else
        %{percent_left: 100, above_warning: false, above_compact: false, at_blocking_limit: false}
      end

    # The two ABSOLUTE thresholds the warning above was derived from, so the TUI
    # can re-derive it from whatever total it currently holds (the status bar
    # self-heals its total from `LlmResponse.input_tokens`, because this event
    # does not fire on every provider/turn) instead of caching a stale banner.
    {compact_at, warn_at} =
      if operative > 0 do
        {CompactionThresholds.compact_at(model_window, model),
         CompactionThresholds.warn_at(model_window, model)}
      else
        {0, 0}
      end

    # Every threshold decision, above `debug`, with the denominator named. The
    # old line reported `max` alone, which was ambiguous between the model's
    # window and the operative one and so could not be used to tell whether a
    # missing compaction was "not yet due" or "never going to fire".
    Logger.info(
      "[ctx] estimated=#{estimated} model_window=#{model_window} " <>
        "operative_window=#{operative}#{if operative < model_window, do: " (clamped)", else: ""} " <>
        "util=#{utilization}% left=#{warning.percent_left}% " <>
        "warn_at=#{warn_at} compact_at=#{compact_at} " <>
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
      max_tokens: model_window,
      model_context_window: model_window,
      context_window_clamped: operative < model_window,
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
         max_tokens: model_window,
         model_context_window: model_window,
         context_window_clamped: operative < model_window,
         utilization: utilization,
         # Item 10 — the session/main row's honest headline: context% of window +
         # real $ cost, so the ROOT row stops presenting a raw, cache-inflated
         # cumulative token count as if it were spend. `context_percent` mirrors
         # `utilization` but is ROUNDED to an integer — the TUI decodes this field
         # as u32 and would drop the whole frame on a float (same contract as the
         # per-agent mirror in ExecutionControl). `cost_usd` is this session's real
         # (per-model cache-discounted) spend, read straight off the loop state.
         context_percent: round(utilization),
         cost_usd: Map.get(state, :session_cost_usd, 0.0),
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

  @doc """
  Context PRESSURE (0.0-100.0): occupancy as a share of the operative window,
  the budget compaction works against, computed synchronously.

  Deliberately not the figure `emit_context_pressure/1` shows on the status
  bar. The bar answers "how much of the model's window is in use" and divides
  by the real window; this answers "how close is the session to compacting"
  and divides by the clamped one. On a model at or below the ceiling the two
  are identical. The homeostat (`Agent.Loop.Regulation.Homeostat`) regulates on
  this one, because its 85% band is meant to fire ahead of compaction, which a
  real-window percentage on a 1M model would never reach. Never raises; a
  resolution failure reads as `0.0`.
  """
  @spec context_utilization(map()) :: float()
  def context_utilization(state) do
    model_window = provider_context_window(state)

    max_tok =
      if model_window > 0,
        do: CompactionThresholds.operative_window(model_window, Map.get(state, :model)),
        else: 0

    estimated = context_occupancy(state)

    if max_tok > 0,
      do: min(100.0, Float.round(estimated / max_tok * 100, 1)),
      else: 0.0
  rescue
    _ -> 0.0
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
  Tokens the context holds RIGHT NOW — the one number behind both the
  status-bar meter and `/context`'s total.

  Once a provider has reported a request size (`last_input_tokens`), that
  report plus an estimate of every message appended after that request (the
  model's reply, tool results folded since, the user's next message). Before
  any report, the char/word estimate of the whole history.

  A history that shrank below the recorded baseline (a compaction) adds
  nothing: the fold paths re-estimate `last_input_tokens` themselves.
  """
  @spec context_occupancy(map()) :: non_neg_integer()
  def context_occupancy(state) do
    messages = Map.get(state, :messages) || []

    case Map.get(state, :last_input_tokens, 0) do
      n when is_integer(n) and n > 0 ->
        n + tokens_since_last_request(messages, Map.get(state, :last_input_message_count))

      _ ->
        OptimalSystemAgent.Agent.Compactor.estimate_tokens(messages)
    end
  end

  defp tokens_since_last_request(messages, count)
       when is_integer(count) and count >= 0 and count <= length(messages) do
    case Enum.drop(messages, count) do
      [] -> 0
      since -> OptimalSystemAgent.Agent.Compactor.estimate_tokens(since)
    end
  end

  defp tokens_since_last_request(_messages, _count), do: 0

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
