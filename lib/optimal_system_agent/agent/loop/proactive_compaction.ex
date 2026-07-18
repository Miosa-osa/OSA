defmodule OptimalSystemAgent.Agent.Loop.ProactiveCompaction do
  @moduledoc """
  Proactive context compaction — summarize BEFORE the context window fills.

  OSA already has a *reactive* recovery path in
  `OptimalSystemAgent.Agent.Loop.ContextCollapse` that fires only after the
  provider returns a 413 / context-overflow error and withholds the largest
  tool results one attempt at a time.

  This module adds the complementary *proactive* layer: it watches context
  utilization on every iteration and, once the estimated token count crosses
  the Claude Code-style reserve threshold (`CompactionThresholds.compact_at/1`
  — window minus output reserve minus a 13k buffer, NOT a fixed 0.75×window
  fraction), it rewrites the message history — folding older turns into a
  structured high-recall
  summary that is explicitly instructed to PRESERVE architectural decisions,
  unresolved bugs, and open todos while DROPPING redundant tool spam. The most
  recent N turns are kept verbatim so in-flight reasoning is never lost.

  Compacting early (rather than only on overflow) keeps the working window lean,
  avoids paying for retries, and preserves signal that the blunt reactive
  withholding would otherwise discard.

  ## Configuration

      config :optimal_system_agent,
        proactive_compaction_enabled: true,
        proactive_compaction_keep_turns: 4,
        proactive_compaction_min_older_tokens: 400,
        compaction_summary_max_tokens: 8_192

  Thresholds come from `OptimalSystemAgent.Agent.Loop.CompactionThresholds`
  (CC reserve math). After 3 consecutive summarization failures a circuit
  breaker opens and auto-compact is disabled for that session until a
  summarization succeeds again.

  Uses the same token estimator the loop uses
  (`OptimalSystemAgent.Agent.Compactor.estimate_tokens/1`).
  """
  require Logger

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.CompactRestore
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.Events.Bus

  @default_keep_turns 4
  @default_min_older_tokens 400
  @max_consecutive_failures 3
  @summary_retries 2

  # Ported from Claude Code `services/compact/prompt.ts` (BASE_COMPACT_PROMPT).
  # The <analysis> block is a drafting scratchpad that strip_analysis/1 removes
  # before the summary reaches context.
  @compact_prompt """
  Your task is to create a detailed summary of the conversation so far, paying close attention to the user's explicit requests and your previous actions.
  This summary should be thorough in capturing technical details, code patterns, and architectural decisions that would be essential for continuing development work without losing context.

  Before providing your final summary, wrap your analysis in <analysis> tags to organize your thoughts and ensure you've covered all necessary points. In your analysis process:

  1. Chronologically analyze each message and section of the conversation. For each section thoroughly identify:
     - The user's explicit requests and intents
     - Your approach to addressing the user's requests
     - Key decisions, technical concepts and code patterns
     - Specific details like file names, full code snippets, function signatures, file edits
     - Errors that you ran into and how you fixed them
     - Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.
  2. Double-check for technical accuracy and completeness, addressing each required element thoroughly.

  Your summary should include the following sections:

  1. Primary Request and Intent: Capture all of the user's explicit requests and intents in detail
  2. Key Technical Concepts: List all important technical concepts, technologies, and frameworks discussed.
  3. Files and Code Sections: Enumerate specific files and code sections examined, modified, or created. Pay special attention to the most recent messages and include full code snippets where applicable and include a summary of why this file read or edit is important.
  4. Errors and fixes: List all errors that you ran into, and how you fixed them. Pay special attention to specific user feedback that you received.
  5. Problem Solving: Document problems solved and any ongoing troubleshooting efforts.
  6. All user messages: List ALL user messages that are not tool results. These are critical for understanding the users' feedback and changing intent.
  7. Pending Tasks: Outline any pending tasks that you have explicitly been asked to work on.
  8. Current Work: Describe in detail precisely what was being worked on immediately before this summary request, paying special attention to the most recent messages from both user and assistant. Include file names and code snippets where applicable.
  9. Optional Next Step: List the next step that you will take that is related to the most recent work you were doing. IMPORTANT: ensure that this step is DIRECTLY in line with the user's most recent explicit requests, and the task you were working on immediately before this summary request. If there is a next step, include direct quotes from the most recent conversation showing exactly what task you were working on and where you left off.

  Structure your output as an <analysis> block followed by a <summary> block containing the 9 numbered sections above.

  Respond with TEXT ONLY. Do NOT call any tools.

  CONVERSATION TO SUMMARIZE:
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
    if enabled?() and not breaker_open?(session_of(state)) do
      estimated_tokens(state) >= CompactionThresholds.compact_at(context_window)
    else
      false
    end
  rescue
    e ->
      Logger.debug("[proactive_compaction] should_compact? failed: #{inspect(e)}")
      false
  end

  @doc """
  True when usage sits inside the context-low warning band — at/above
  `CompactionThresholds.warn_at/1` but below the auto-compact threshold.
  The cheap standalone microcompact pass (truncate stale tool results, no
  LLM call) runs here to delay full compaction.
  """
  @spec should_microcompact?(map(), term()) :: boolean()
  def should_microcompact?(_state, context_window)
      when not is_integer(context_window) or context_window <= 0,
      do: false

  def should_microcompact?(state, context_window) do
    if enabled?() do
      tokens = estimated_tokens(state)

      tokens >= CompactionThresholds.warn_at(context_window) and
        tokens < CompactionThresholds.compact_at(context_window)
    else
      false
    end
  rescue
    _ -> false
  end

  @doc """
  Compact a message list by summarizing older turns into a structured,
  Claude Code-style summary message, keeping the most recent N turns verbatim.

  On success the compacted list is:

      [compact-boundary summary | post-compaction restore (files/tasks) | recent verbatim]

  Returns the (possibly unchanged) message list. On any summarization failure
  the original list is returned untouched (and a failure is recorded toward the
  circuit breaker) so callers can safely fall through to the reactive
  `ContextCollapse` path without breaking the turn.
  """
  @spec compact([map()], String.t() | nil) :: [map()]
  def compact(messages, session_id \\ nil)

  def compact(messages, session_id) when is_list(messages) do
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

        case summarize_with_retries(older, @summary_retries) do
          {:ok, summary} ->
            reset_failures(session_id)

            summary_msg = %{role: "system", content: compact_boundary_content(summary)}

            restore =
              case CompactRestore.build_restore_message(session_id) do
                nil -> []
                msg -> [msg]
              end

            compacted = [summary_msg | restore] ++ recent
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
            failures = record_failure(session_id)

            if failures >= @max_consecutive_failures do
              Logger.warning(
                "[proactive_compaction] summary failed #{failures}x consecutively — " <>
                  "circuit breaker OPEN, auto-compact disabled until a success: #{inspect(reason)}"
              )
            else
              Logger.warning(
                "[proactive_compaction] summary failed, keeping history: #{inspect(reason)}"
              )
            end

            messages
        end
    end
  end

  def compact(messages, _session_id), do: messages

  # Compact-boundary message: CC continuation preamble + formatted summary
  # (analysis scratchpad stripped) + resume-without-recap instruction.
  @doc false
  def compact_boundary_content(summary) do
    "[Compact boundary]\n" <>
      "This session is being continued from a previous conversation that ran out of context. " <>
      "The summary below covers the earlier portion of the conversation.\n\n" <>
      strip_analysis(summary) <>
      "\n\nRecent messages are preserved verbatim. Continue the conversation from where it left " <>
      "off without asking the user any further questions. Resume directly — do not acknowledge " <>
      "the summary, do not recap what was happening. Pick up the last task as if the break " <>
      "never happened."
  end

  # Port of CC `formatCompactSummary`: drop the <analysis> drafting scratchpad,
  # extract the <summary> body under a readable header.
  @doc false
  def strip_analysis(summary) when is_binary(summary) do
    stripped = Regex.replace(~r/<analysis>[\s\S]*?<\/analysis>/, summary, "")

    formatted =
      case Regex.run(~r/<summary>([\s\S]*?)<\/summary>/, stripped) do
        [_, content] -> "Summary:\n" <> String.trim(content)
        _ -> stripped
      end

    formatted
    |> String.replace(~r/\n\n+/, "\n\n")
    |> String.trim()
  end

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

  # Retry the summarization LLM call up to `retries_left` additional times
  # (CC compact does 2 streaming retries before giving up).
  defp summarize_with_retries(messages, retries_left) do
    case summarize(messages) do
      {:ok, _} = ok ->
        ok

      {:error, _reason} when retries_left > 0 ->
        summarize_with_retries(messages, retries_left - 1)

      error ->
        error
    end
  end

  @spec summarize([map()]) :: {:ok, String.t()} | {:error, term()}
  defp summarize([]), do: {:error, :empty}

  defp summarize(messages) do
    if not llm_enabled?() do
      # Test/offline stub — mirrors Compactor's :compactor_llm_enabled gate.
      {:ok, "<summary>[Stub summary of #{length(messages)} messages]</summary>"}
    else
      prompt = String.replace(@compact_prompt, "%MESSAGES%", format_messages(messages))

      try do
        case Providers.chat([%{role: "user", content: prompt}],
               temperature: 0.2,
               max_tokens: summary_max_tokens()
             ) do
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
  end

  @spec format_messages([map()]) :: String.t()
  defp format_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      role = role_of(msg)
      content = content_for_summary(Map.get(msg, :content) || Map.get(msg, "content"))

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

  # Content normalization for summarization: keep text blocks, drop image
  # payloads (base64 blobs would blow the summarizer's own window).
  defp content_for_summary(content) when is_binary(content), do: content

  defp content_for_summary(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text} = block -> safe_to_string(Map.get(block, :text))
      %{type: "text"} = block -> safe_to_string(Map.get(block, :text))
      %{"type" => "text"} = block -> safe_to_string(Map.get(block, "text"))
      %{type: t} when t in [:image, :image_url, "image", "image_url"] -> "[image omitted]"
      %{"type" => t} when t in ["image", "image_url"] -> "[image omitted]"
      other -> safe_to_string(other)
    end)
    |> Enum.join("\n")
  end

  defp content_for_summary(other), do: safe_to_string(other)

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
      strategy: :proactive
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

  defp llm_enabled?,
    do: Application.get_env(:optimal_system_agent, :compactor_llm_enabled, true)

  defp summary_max_tokens do
    case Application.get_env(:optimal_system_agent, :compaction_summary_max_tokens, 8_192) do
      n when is_integer(n) and n > 0 -> n
      _ -> 8_192
    end
  end

  # ── Failure circuit breaker (CC MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES) ──────
  #
  # 3 consecutive summarization failures open the breaker: should_compact?
  # returns false for that session until a summarization succeeds, so an
  # irrecoverably-over-limit context can't burn an LLM call every iteration.

  @doc false
  def breaker_open?(session_id),
    do: failure_count(session_id) >= @max_consecutive_failures

  defp failure_count(session_id) do
    case :ets.lookup(:osa_compactor_state, {:compact_failures, session_id || :global}) do
      [{_key, n}] when is_integer(n) -> n
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp record_failure(session_id) do
    key = {:compact_failures, session_id || :global}
    :ets.update_counter(:osa_compactor_state, key, {2, 1}, {key, 0})
  rescue
    _ -> 0
  end

  defp reset_failures(session_id) do
    :ets.delete(:osa_compactor_state, {:compact_failures, session_id || :global})
    :ok
  rescue
    _ -> :ok
  end

  defp session_of(state), do: Map.get(state, :session_id)

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
