defmodule OptimalSystemAgent.Agent.Loop.ModelSwap do
  @moduledoc """
  Mid-conversation provider/model switch.

  `Loop.handle_call({:swap_provider, ...})` used to write `provider`, `model`,
  and `effective_context_window` and stop. The transcript stayed as-is, the
  TUI zeroed the context bar, and compaction waited until the next turn —
  which, hopping from a 1M model at 40% occupancy onto a 200k window, is
  already past `compact_at` of the new window.

  This module is that missing logic:

    * same transcript, new window
    * compact **during the swap** only when the window **shrinks** and occupancy
      already exceeds the new `compact_at` (quota/rate-limit hops of equal or
      larger windows do not compact)
    * tell the operator old window / new window / tokens / compacted yes-or-no
    * warn (do not silently send) when the static prompt cannot fit

  `updates.jsonl` is never rewritten; compaction only shrinks live `messages`.
  """

  require Logger

  alias OptimalSystemAgent.Agent.CompactionEvents
  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Soul

  @type info :: %{
          required(:provider) => atom(),
          required(:model) => String.t(),
          required(:context_window) => pos_integer() | nil,
          optional(:old_provider) => atom() | nil,
          optional(:old_model) => String.t() | nil,
          optional(:old_context_window) => pos_integer() | nil,
          optional(:tokens_before) => non_neg_integer(),
          optional(:tokens_after) => non_neg_integer(),
          optional(:compacted) => boolean(),
          optional(:compaction_reason) => String.t() | nil,
          optional(:warning) => String.t() | nil
        }

  @doc """
  What a swap *would* do. Public so the decision is unit-testable without an
  LLM summarizer round-trip.

    * `:keep`     — rewrite provider/model/window, leave the transcript
    * `:compact`  — window shrank and occupancy is already past the new compact_at
  """
  @spec plan(term(), term(), non_neg_integer(), non_neg_integer()) :: :keep | :compact
  def plan(old_window, new_window, occupancy, message_count)
      when is_integer(occupancy) and occupancy >= 0 and is_integer(message_count) and
             message_count >= 0 do
    cond do
      not compactable_window?(new_window) -> :keep
      occupancy <= 0 or message_count == 0 -> :keep
      not window_shrunk?(old_window, new_window) -> :keep
      occupancy >= CompactionThresholds.compact_at(new_window) -> :compact
      true -> :keep
    end
  end

  def plan(_, _, _, _), do: :keep

  @doc """
  Apply the swap to loop state. Returns `{new_state, info}` where `info` is
  what HTTP / CLI / TUI print. Never raises — a failed compact leaves the
  transcript and still completes the provider change.
  """
  @spec apply(map(), atom(), String.t(), pos_integer() | nil) :: {map(), info()}
  def apply(state, provider_atom, model, new_window)
      when is_atom(provider_atom) and is_binary(model) do
    old_provider = Map.get(state, :provider)
    old_model = Map.get(state, :model)
    # The Loop struct's `:effective_context_window` is often nil — `init/1`
    # never filled it. A nil here used to mean "treat as shrink", which
    # compacted quota hops onto the same-size model. Resolve from the OLD
    # model/provider the same way compaction does.
    old_window = resolve_window(state)
    occupancy = occupancy(state)
    message_count = length(Map.get(state, :messages, []) || [])

    state = %{
      state
      | provider: provider_atom,
        model: model,
        effective_context_window: new_window
    }

    decision = plan(old_window, new_window, occupancy, message_count)

    {state, compacted?, tokens_after, reason} =
      case decision do
        :compact -> compact_for_new_window(state, occupancy, new_window)
        :keep -> {state, false, occupancy, nil}
      end

    warning = fit_warning(provider_atom, model, new_window)

    info = %{
      provider: provider_atom,
      model: model,
      context_window: new_window,
      old_provider: old_provider,
      old_model: old_model,
      old_context_window: old_window,
      tokens_before: occupancy,
      tokens_after: tokens_after,
      compacted: compacted?,
      compaction_reason: reason,
      warning: warning
    }

    emit_switched(state, info)
    persist_live_messages(state, compacted?)

    {state, info}
  end

  @doc false
  @spec occupancy(map()) :: non_neg_integer()
  def occupancy(state) when is_map(state) do
    case Map.get(state, :last_input_tokens, 0) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        messages = Map.get(state, :messages, []) || []
        Compactor.estimate_tokens(messages)
    end
  end

  def occupancy(_), do: 0

  # -- compact --------------------------------------------------------------

  defp compact_for_new_window(state, occupancy, new_window) do
    messages = state.messages || []
    session_id = state.session_id
    tokens_before = occupancy

    Logger.info(
      "[model-swap] compacting #{tokens_before} tokens into #{new_window}-token window " <>
        "(session #{session_id})"
    )

    CompactionEvents.started(session_id, :model_switch, tokens_before)
    started_at = System.monotonic_time(:millisecond)

    force? = occupancy >= new_window

    compacted =
      TurnPipeline.bounded_compaction(messages, fn ->
        Compactor.maybe_compact(
          messages,
          occupancy,
          session_id,
          context_window: new_window,
          force: force?
        )
      end) || messages

    tokens_after = Compactor.estimate_tokens(compacted)
    did? = compacted != messages

    CompactionEvents.completed(session_id,
      tokens_before: tokens_before,
      tokens_after: tokens_after,
      messages_before: length(messages),
      messages_after: length(compacted),
      duration_ms: System.monotonic_time(:millisecond) - started_at
    )

    reason =
      if did? do
        "window_shrunk"
      else
        nil
      end

    state =
      if did? do
        %{state | messages: compacted, last_input_tokens: tokens_after}
      else
        state
      end

    {state, did?, tokens_after, reason}
  rescue
    e ->
      Logger.error("[model-swap] compact failed: #{Exception.message(e)} — transcript kept")
      {state, false, occupancy, nil}
  end

  defp persist_live_messages(state, true) do
    SessionPersistence.save(state.session_id, state.messages || [], state.working_dir)
    :ok
  rescue
    _ -> :ok
  end

  defp persist_live_messages(_state, _), do: :ok

  # -- warnings -------------------------------------------------------------

  # Static prompt + native tool schemas + response reserve have to fit the new
  # window on the first call after switch. Warn hard; do not refuse — a quota
  # hop onto a small local model is exactly when the operator still needs the
  # session.
  defp fit_warning(provider, _model, window) when is_integer(window) and window > 0 do
    variant = OptimalSystemAgent.Agent.Context.static_base_variant(provider, small?(window))
    static = Soul.static_token_count(variant)
    tools = OptimalSystemAgent.Agent.Context.tool_schema_token_count()
    reserve = 8_192
    floor = static + tools + reserve

    cond do
      window < floor ->
        "static prompt (~#{static}) + tool schemas (~#{tools}) need ~#{floor} tokens; " <>
          "#{window} may not fit. First turn after this switch can overflow."

      small?(window) ->
        "new window is #{window} tokens (lite prompt). Expect a trimmed tool list."

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp fit_warning(_, _, _), do: nil

  defp small?(window) when is_integer(window),
    do: window < OptimalSystemAgent.Agent.Context.small_window_tokens()

  defp small?(_), do: false

  # -- emit -----------------------------------------------------------------

  defp emit_switched(state, info) do
    session_id = Map.get(state, :session_id)

    payload = %{
      type: :system_event,
      event: :model_switched,
      session_id: session_id,
      provider: to_string(info.provider),
      model: info.model,
      context_window: info.context_window,
      old_provider: info[:old_provider] && to_string(info.old_provider),
      old_model: info[:old_model],
      old_context_window: info[:old_context_window],
      tokens_before: info.tokens_before,
      tokens_after: info.tokens_after,
      compacted: info.compacted,
      warning: info.warning
    }

    if is_binary(session_id) and session_id != "" do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{session_id}",
        {:osa_event, payload}
      )
    end

    Bus.emit(:system_event, payload)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- helpers --------------------------------------------------------------

  defp compactable_window?(n) when is_integer(n) and n > 0, do: true
  defp compactable_window?(_), do: false

  defp window_shrunk?(old, new)
       when is_integer(old) and old > 0 and is_integer(new) and new > 0,
       do: new < old

  # Unknown previous window: do not compact. Quota hops (same-size model,
  # unresolved stored field) must keep the transcript. Overflow recovery on
  # the next turn still exists if the new window is genuinely too small.
  defp window_shrunk?(_, _), do: false

  defp resolve_window(state) when is_map(state) do
    case Map.get(state, :effective_context_window) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case OptimalSystemAgent.Agent.Loop.ContextWindow.resolve(state) do
          {:ok, n} when is_integer(n) and n > 0 -> n
          _ -> nil
        end
    end
  end

  defp resolve_window(_), do: nil
end
