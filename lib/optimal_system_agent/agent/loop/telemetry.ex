defmodule OptimalSystemAgent.Agent.Loop.Telemetry do
  @moduledoc """
  Context pressure and token estimation telemetry for the agent loop.

  Emits `context_pressure` events to the Events.Bus and Phoenix.PubSub so the
  TUI status bar can display live context window utilization.
  """
  require Logger

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
    max_tok = provider_context_window(state)

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
        do: OptimalSystemAgent.Agent.Loop.CompactionThresholds.used_percent(estimated, max_tok),
        else: 0.0

    warning =
      if is_integer(max_tok) and max_tok > 0 do
        OptimalSystemAgent.Agent.Loop.CompactionThresholds.warning_state(estimated, max_tok)
      else
        %{percent_left: 100, above_warning: false, above_compact: false, at_blocking_limit: false}
      end

    Logger.info("[ctx] estimated=#{estimated} max=#{max_tok} util=#{utilization}%")

    Bus.emit(:system_event, %{
      event: :context_pressure,
      session_id: state.session_id,
      estimated_tokens: estimated,
      max_tokens: max_tok,
      utilization: utilization,
      percent_left: warning.percent_left,
      context_low: warning.above_warning,
      above_compact: warning.above_compact,
      at_blocking_limit: warning.at_blocking_limit
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
         utilization: utilization,
         percent_left: warning.percent_left,
         context_low: warning.above_warning,
         above_compact: warning.above_compact,
         at_blocking_limit: warning.at_blocking_limit
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

      is_nil(provider) ->
        Registry.context_window(model)

      true ->
        case Registry.effective_context_window(model, provider) do
          cw when is_integer(cw) and cw > 0 -> cw
          _ -> Registry.context_window(model)
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
