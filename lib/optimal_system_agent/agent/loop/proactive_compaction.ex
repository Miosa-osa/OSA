defmodule OptimalSystemAgent.Agent.Loop.ProactiveCompaction do
  @moduledoc """
  Proactive context compaction — summarize BEFORE the context window fills.

  OSA already has a *reactive* recovery path in
  `OptimalSystemAgent.Agent.Loop.ContextCollapse` that fires only after the
  provider returns a 413 / context-overflow error and withholds the largest
  tool results one attempt at a time.

  This module adds the complementary *proactive* layer: it watches context
  utilization on every iteration and, once the estimated token count crosses a
  configurable fraction of the model's context window (default `0.75`), it
  rewrites the message history — folding older turns into a single high-recall
  summary that is explicitly instructed to PRESERVE architectural decisions,
  unresolved bugs, and open todos while DROPPING redundant tool spam. The most
  recent N turns are kept verbatim so in-flight reasoning is never lost.

  Compacting early (rather than only on overflow) keeps the working window lean,
  avoids paying for retries, and preserves signal that the blunt reactive
  withholding would otherwise discard.

  ## Configuration

      config :optimal_system_agent,
        proactive_compaction_enabled: true,
        proactive_compaction_threshold: 0.75,
        proactive_compaction_keep_turns: 4,
        proactive_compaction_min_older_tokens: 400

  Uses the same token estimator the loop uses
  (`OptimalSystemAgent.Agent.Compactor.estimate_tokens/1`).
  """
  require Logger

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Events.Bus

  @default_threshold 0.75
  @default_keep_turns 4
  @default_min_older_tokens 400

  @preserve_instruction """
  You are compacting an agent conversation to free context BEFORE the window \
  fills. Produce a terse, high-recall summary of the excerpt below.

  PRESERVE (never lose these):
  - Architectural decisions and the reasoning behind them
  - Unresolved bugs, errors, failing tests, and their causes
  - Open todos / next steps that are not yet done
  - Concrete details: file paths, line numbers, symbol names, config values, commands run

  DROP (safe to discard):
  - Redundant or superseded tool outputs (file dumps, long search results, directory listings)
  - Chatter that led nowhere and has no bearing on remaining work

  Use bullet points. Do not invent facts. Output only the summary.

  %MESSAGES%
  """

  @doc """
  Return `true` when the state's estimated token usage exceeds the compaction
  threshold for the given `context_window`.

  Mirrors `Telemetry.emit_context_pressure/1`: prefers the provider-reported
  `last_input_tokens` when available, otherwise falls back to the word-count
  heuristic in `Compactor.estimate_tokens/1`.
  """
  @spec should_compact?(map(), non_neg_integer()) :: boolean()
  def should_compact?(_state, context_window)
      when not is_integer(context_window) or context_window <= 0,
      do: false

  def should_compact?(state, context_window) do
    if enabled?() do
      estimated = estimated_tokens(state)
      budget = trunc(context_window * threshold())
      estimated >= budget
    else
      false
    end
  rescue
    e ->
      Logger.debug("[proactive_compaction] should_compact? failed: #{inspect(e)}")
      false
  end

  @doc """
  Compact a message list by summarizing older turns into a single high-recall
  summary message, keeping the most recent N turns verbatim.

  Returns the (possibly unchanged) message list. On any summarization failure
  the original list is returned untouched so callers can safely fall through to
  the reactive `ContextCollapse` path without breaking the turn.
  """
  @spec compact([map()]) :: [map()]
  def compact(messages) when is_list(messages) do
    {older, recent} = split_turns(messages, keep_turns())
    older_tokens = Compactor.estimate_tokens(older)

    cond do
      older == [] ->
        messages

      older_tokens < min_older_tokens() ->
        # Not worth an LLM round-trip; leave history as-is.
        messages

      true ->
        fire_compact_hook(:pre_compact, %{
          phase: :pre,
          strategy: :proactive,
          tokens_before: older_tokens
        })

        case summarize(older) do
          {:ok, summary} ->
            summary_msg = %{
              role: "system",
              content: "[Proactive Context Summary — older turns folded to save context]\n" <> summary
            }

            compacted = [summary_msg | recent]
            after_tokens = Compactor.estimate_tokens(compacted)

            fire_compact_hook(:post_compact, %{
              phase: :post,
              strategy: :proactive,
              tokens_before: older_tokens,
              tokens_after: after_tokens,
              tokens_saved: older_tokens - after_tokens
            })

            emit_event(length(messages), length(compacted), older_tokens, after_tokens)

            Logger.info(
              "[proactive_compaction] folded #{length(older)} older messages into 1 summary " <>
                "(~#{older_tokens} → ~#{Compactor.estimate_tokens([summary_msg])} tokens; " <>
                "kept #{length(recent)} recent verbatim)"
            )

            compacted

          {:error, reason} ->
            Logger.warning("[proactive_compaction] summary failed, keeping history: #{inspect(reason)}")
            messages
        end
    end
  end

  def compact(messages), do: messages

  # ---------------------------------------------------------------------------
  # Turn splitting
  # ---------------------------------------------------------------------------

  # Split `messages` into `{older, recent}` where `recent` holds the last
  # `keep` turns verbatim. A turn boundary starts at each `role: "user"`
  # message; leading non-user messages (e.g. a system preamble) stay with the
  # first turn so they are never orphaned.
  @spec split_turns([map()], non_neg_integer()) :: {[map()], [map()]}
  defp split_turns(messages, keep) when keep <= 0, do: {messages, []}

  defp split_turns(messages, keep) do
    boundaries =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, idx} -> idx > 0 and role_of(msg) == "user" end)
      |> Enum.map(fn {_msg, idx} -> idx end)

    # Keep the last `keep` turns → the split point is the boundary `keep` turns
    # back from the end.
    case Enum.take(boundaries, -keep) do
      [] ->
        # Zero or one turn total; nothing older to compact.
        {[], messages}

      kept_boundaries ->
        split_at = List.first(kept_boundaries)

        if length(boundaries) < keep do
          {[], messages}
        else
          {Enum.take(messages, split_at), Enum.drop(messages, split_at)}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Summarization
  # ---------------------------------------------------------------------------

  @spec summarize([map()]) :: {:ok, String.t()} | {:error, term()}
  defp summarize([]), do: {:error, :empty}

  defp summarize(messages) do
    prompt = String.replace(@preserve_instruction, "%MESSAGES%", format_messages(messages))

    try do
      case Providers.chat([%{role: "user", content: prompt}], temperature: 0.2, max_tokens: 800) do
        {:ok, %{content: content}} when is_binary(content) and content != "" ->
          {:ok, content}

        {:ok, %{content: other}} ->
          {:error, {:empty_summary, other}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    end
  end

  @spec format_messages([map()]) :: String.t()
  defp format_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      role = role_of(msg)
      content = safe_to_string(Map.get(msg, :content) || Map.get(msg, "content"))

      tool_suffix =
        case Map.get(msg, :tool_calls) do
          calls when is_list(calls) and calls != [] ->
            names = calls |> Enum.map(&safe_to_string(Map.get(&1, :name, ""))) |> Enum.join(", ")
            " [tool_calls: #{names}]"

          _ ->
            ""
        end

      "#{role}: #{content}#{tool_suffix}"
    end)
    |> Enum.join("\n\n")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @spec estimated_tokens(map()) :: non_neg_integer()
  defp estimated_tokens(state) do
    last = Map.get(state, :last_input_tokens, 0)

    if is_integer(last) and last > 0 do
      last
    else
      Compactor.estimate_tokens(Map.get(state, :messages, []))
    end
  end

  @spec emit_event(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  defp emit_event(before_count, after_count, before_tokens, after_tokens) do
    Bus.emit(:system_event, %{
      event: :proactive_compaction,
      messages_before: before_count,
      messages_after: after_count,
      tokens_before: before_tokens,
      tokens_after: after_tokens,
      threshold: threshold()
    })

    :ok
  rescue
    _ -> :ok
  end

  # Fire a compaction lifecycle hook (pre_compact / post_compact). Fire-and-forget.
  defp fire_compact_hook(event, payload) do
    OptimalSystemAgent.Agent.Hooks.run_async(event, payload)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp role_of(msg), do: to_string(Map.get(msg, :role) || Map.get(msg, "role") || "")

  defp safe_to_string(nil), do: ""
  defp safe_to_string(v) when is_binary(v), do: v
  defp safe_to_string(v), do: inspect(v)

  defp enabled?,
    do: Application.get_env(:optimal_system_agent, :proactive_compaction_enabled, true)

  defp threshold do
    case Application.get_env(:optimal_system_agent, :proactive_compaction_threshold, @default_threshold) do
      t when is_number(t) and t > 0 and t <= 1 -> t
      _ -> @default_threshold
    end
  end

  defp keep_turns do
    case Application.get_env(:optimal_system_agent, :proactive_compaction_keep_turns, @default_keep_turns) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_keep_turns
    end
  end

  defp min_older_tokens do
    case Application.get_env(
           :optimal_system_agent,
           :proactive_compaction_min_older_tokens,
           @default_min_older_tokens
         ) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_min_older_tokens
    end
  end
end
