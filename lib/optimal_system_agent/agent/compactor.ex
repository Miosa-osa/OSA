defmodule OptimalSystemAgent.Agent.Compactor do
  @moduledoc """
  Intelligent sliding-window context compaction with importance-weighted retention.

  ## Architecture

  The compactor divides the conversation into three zones and applies
  progressively heavier compression as messages age:

      Zone 1 — HOT  (last 10 messages): Verbatim, never touched.
      Zone 2 — WARM (messages 11-30):   Progressive compression pipeline.
      Zone 3 — COLD (messages 31+):     Collapsed to a single key-facts summary.

  ## Progressive Compression Pipeline

  Instead of a single jump from "full messages" to "emergency truncate",
  compression proceeds through discrete steps. After each step the total
  token count is checked — the pipeline stops as soon as usage drops below
  the target threshold.

      Step 1  Strip tool-call argument details (keep name + result only)
      Step 2  Merge consecutive same-role messages
      Step 3  Summarize groups of 5 warm-zone messages (LLM call)
      Step 4  Compress cold zone to key-facts (LLM call)
      Step 5  Emergency truncate (last resort, no LLM)

  ## Importance-Weighted Retention

  Not all messages are equal. An importance score determines how long a
  message resists compression:

      Tool calls present   → +50% retention bonus
      Long/substantive     → up to +30% retention bonus (length / 500, capped)
      Pure acknowledgment  → -50% retention (compressed first)

  Messages with higher importance scores are kept verbatim longer during
  warm-zone compression.

  ## Token Estimation

  Uses a word + punctuation heuristic instead of the naive `len / 4`:

      words * 1.3 + punctuation * 0.5

  ## Public API

      maybe_compact/1       — inspect and possibly compact a message list
      stats/0               — compaction metrics from the GenServer
      start_link/1          — GenServer lifecycle
      utilization/1         — context-window utilization percentage
      estimate_tokens/1     — token estimate for a string or message list
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.PromptLoader

  defp max_tokens, do: Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
  defp tier1_threshold, do: Application.get_env(:optimal_system_agent, :compaction_warn, 0.85)

  defp tier2_threshold,
    do: Application.get_env(:optimal_system_agent, :compaction_aggressive, 0.85)

  defp tier3_threshold,
    do: Application.get_env(:optimal_system_agent, :compaction_emergency, 0.95)

  # Zone boundaries (counted from the end of the non-system message list)
  @hot_zone_size 20
  @warm_zone_end 50

  # Acknowledgment patterns — these get compressed first
  @ack_patterns ~r/\A\s*(ok|okay|sure|thanks|thank you|got it|yes|no|yep|nope|k|kk|alright|cool|nice|great|perfect|noted|ack|roger|👍|👌)\s*[\.\!\?]?\s*\z/iu

  # ---------------------------------------------------------------------------
  # GenServer state
  # ---------------------------------------------------------------------------

  defstruct compaction_count: 0,
            tokens_saved: 0,
            last_compacted_at: nil,
            pipeline_steps_used: %{}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start the Compactor GenServer."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Returns current compaction metrics including per-step usage counts.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Inspects the given message list and compacts it if any usage threshold is
  exceeded. Returns the (possibly compacted) message list.

  `known_tokens` is an optional REAL, provider-reported input-token count for
  the current context (from `Loop.Accounting` / the budget stage). When it is a
  positive integer it drives the compaction *decision* (usage ratio) instead of
  the word-count heuristic — the heuristic under-counts because it ignores the
  system prompt + tool schemas that also consume the window. `nil`/`0` falls
  back to the estimate, preserving the original `maybe_compact/1` behaviour.

  This function is safe — it never raises. On any unexpected error it returns
  the original messages unchanged.
  """
  @spec maybe_compact([map()], non_neg_integer() | nil, String.t() | nil) :: [map()]
  def maybe_compact(messages, known_tokens \\ nil, session_id \\ nil) do
    try do
      do_maybe_compact(messages, known_tokens, session_id)
    rescue
      e ->
        Logger.error("Compactor.maybe_compact crashed: #{Exception.message(e)}")
        messages
    end
  end

  @doc """
  Run micro-compaction independently — clears old tool results without LLM call.
  Can be called on a timer for lightweight context maintenance.
  """
  @spec micro_compact([map()]) :: [map()]
  def micro_compact(messages) do
    {system_msgs, non_system} = split_system(messages)
    annotated = annotate_importance(non_system)
    {compacted, _, _} = apply_step(:micro_compact, annotated, system_msgs, 0)
    system_msgs ++ strip_annotations(compacted)
  rescue
    _ -> messages
  end

  @doc """
  Returns context window utilization as a percentage (0.0 — 100.0).
  """
  @spec utilization([map()]) :: float()
  def utilization(messages) when is_list(messages) do
    tokens = estimate_tokens(messages)
    Float.round(tokens / max_tokens() * 100, 1)
  end

  @doc """
  Estimates token count for a message list or a text string.

  For message lists: sums per-message token estimates including tool call
  overhead and a 4-token per-message framing cost.

  For strings: uses a word + punctuation heuristic —
  words * 1.3 + punctuation * 0.5.
  """
  @spec estimate_tokens([map()] | String.t() | nil) :: non_neg_integer()
  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content_tokens = estimate_tokens(safe_to_string(Map.get(msg, :content)))

      tool_call_tokens =
        case Map.get(msg, :tool_calls) do
          nil ->
            0

          [] ->
            0

          calls when is_list(calls) ->
            Enum.reduce(calls, 0, fn tc, tc_acc ->
              name_tokens = estimate_tokens(safe_to_string(Map.get(tc, :name, "")))
              arg_tokens = estimate_tokens(safe_to_string(Map.get(tc, :arguments, "")))
              tc_acc + name_tokens + arg_tokens + 4
            end)

          _ ->
            0
        end

      # Per-message overhead (role label, delimiters)
      acc + content_tokens + tool_call_tokens + 4
    end)
  end

  def estimate_tokens(nil), do: 0

  def estimate_tokens(text) when is_binary(text) do
    if text == "", do: 0, else: estimate_tokens_heuristic(text)
  end

  @doc false
  defp estimate_tokens_heuristic(text),
    do: OptimalSystemAgent.Utils.Tokens.estimate(text)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%__MODULE__{} = state) do
    Logger.info("Compactor started (max_tokens=#{max_tokens()})")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    metrics = %{
      compaction_count: state.compaction_count,
      tokens_saved: state.tokens_saved,
      last_compacted_at: state.last_compacted_at,
      pipeline_steps_used: state.pipeline_steps_used
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_cast({:record_compaction, tokens_saved, step}, state) do
    step_counts = Map.update(state.pipeline_steps_used, step, 1, &(&1 + 1))

    updated = %{
      state
      | compaction_count: state.compaction_count + 1,
        tokens_saved: state.tokens_saved + tokens_saved,
        last_compacted_at: DateTime.utc_now(),
        pipeline_steps_used: step_counts
    }

    {:noreply, updated}
  end

  # ---------------------------------------------------------------------------
  # Core compaction logic
  # ---------------------------------------------------------------------------

  @doc false
  defp do_maybe_compact(messages, known_tokens, session_id) do
    # Message-only heuristic estimate — used for the pipeline's savings math so
    # before/after token counts stay in the same unit.
    estimated = estimate_tokens(messages)

    # Decision token count: prefer the real provider-reported input tokens when
    # available (they include system prompt + tool schemas the estimate omits),
    # else fall back to the heuristic estimate.
    decision_tokens =
      case known_tokens do
        n when is_integer(n) and n > 0 -> n
        _ -> estimated
      end

    max_tok = max_tokens()
    usage_ratio = decision_tokens / max_tok

    cond do
      usage_ratio > tier3_threshold() ->
        Logger.warning(
          "Compactor: usage at #{pct(usage_ratio)} — running full pipeline (emergency)"
        )

        run_pipeline(messages, estimated, :emergency, max_tok, session_id)

      usage_ratio > tier2_threshold() ->
        Logger.info("Compactor: usage at #{pct(usage_ratio)} — running aggressive pipeline")
        run_pipeline(messages, estimated, :aggressive, max_tok, session_id)

      usage_ratio > tier1_threshold() ->
        Logger.info("Compactor: usage at #{pct(usage_ratio)} — running background pipeline")
        run_pipeline(messages, estimated, :background, max_tok, session_id)

      true ->
        messages
    end
  end

  # ---------------------------------------------------------------------------
  # Progressive compression pipeline
  # ---------------------------------------------------------------------------

  @doc false
  defp run_pipeline(messages, tokens_before, severity, max_tok, session_id) do
    # PreCompact hook — SYNCHRONOUS (CC parity). Command hooks receive the
    # full event on stdin and can contribute custom summarization
    # instructions (additionalContext / exit-0 stdout), threaded into every
    # summary LLM prompt for this compaction run. PreCompact cannot veto
    # compaction — a blocking hook is logged and compaction proceeds.
    compact_instructions =
      try do
        case OptimalSystemAgent.Agent.Hooks.run(:pre_compact, %{
               phase: :pre,
               trigger: "auto",
               custom_instructions: "",
               tokens_before: tokens_before,
               severity: severity,
               session_id: session_id
             }) do
          {:ok, final} ->
            final
            |> Map.get(:injected_context, [])
            |> Enum.map(&to_string/1)
            |> Enum.join("\n")
            |> String.trim()

          {:blocked, reason} ->
            Logger.warning("Compactor: PreCompact hook reported #{inspect(reason)} — proceeding")
            ""

          _ ->
            ""
        end
      rescue
        _ -> ""
      catch
        :exit, _ -> ""
      end

    if compact_instructions == "" do
      Process.delete(:osa_compact_instructions)
    else
      Process.put(:osa_compact_instructions, compact_instructions)
    end

    # Determine target: bring usage to 70% for background, 60% for aggressive/emergency
    target_tokens =
      case severity do
        :background -> round(max_tok * 0.70)
        :aggressive -> round(max_tok * 0.60)
        :emergency -> round(max_tok * 0.50)
      end

    {system_msgs, non_system} = split_system(messages)

    # Sort non-system by importance for selective retention
    annotated = annotate_importance(non_system)

    # Run pipeline steps sequentially, stopping when under budget
    # Step 0 (micro-compact) is the cheapest — no LLM call, just truncates old tool results
    result =
      {annotated, system_msgs, :none}
      |> pipeline_step(:micro_compact, target_tokens)
      |> pipeline_step(:strip_tool_args, target_tokens)
      |> pipeline_step(:merge_consecutive, target_tokens)
      |> pipeline_step(:summarize_warm, target_tokens)
      |> pipeline_step(:compress_cold, target_tokens)
      |> pipeline_step(:emergency_truncate, target_tokens)

    {final_annotated, final_system, last_step} = result
    final_messages = final_system ++ strip_annotations(final_annotated)

    # Post-compact restore: re-inject working context (files, tasks, workspace)
    final_messages =
      case OptimalSystemAgent.Agent.CompactRestore.build_restore_message(session_id) do
        nil -> final_messages
        restore_msg -> final_messages ++ [restore_msg]
      end

    tokens_after = estimate_tokens(final_messages)
    saved = tokens_before - tokens_after

    if saved > 0 do
      record_compaction(saved, last_step)

      # Emit post_compact hook event
      try do
        OptimalSystemAgent.Agent.Hooks.run_async(:post_compact, %{
          phase: :post,
          tokens_before: tokens_before,
          tokens_after: tokens_after,
          tokens_saved: saved,
          severity: severity,
          last_step: last_step
        })
      rescue
        _ -> :ok
      end
    end

    Logger.info(
      "Compactor pipeline (#{severity}): #{tokens_before} -> #{tokens_after} tokens " <>
        "(saved #{saved}, last_step=#{last_step})"
    )

    final_messages
  end

  # Pipeline step dispatcher — skips if already under budget
  @doc false
  defp pipeline_step({annotated, system_msgs, prev_step}, step, target_tokens) do
    current_tokens =
      estimate_tokens(system_msgs) + estimate_tokens(strip_annotations(annotated))

    if current_tokens <= target_tokens do
      # Already under budget — skip remaining steps
      {annotated, system_msgs, prev_step}
    else
      apply_step(step, annotated, system_msgs, target_tokens)
    end
  end

  # Step 0: Micro-compact — truncate old tool results without LLM call.
  # Keeps the last N tool results intact, truncates older ones.
  # This is the cheapest possible compaction step.
  @micro_compact_keep Application.compile_env(
                        :optimal_system_agent,
                        :micro_compact_keep_recent,
                        5
                      )

  @doc false
  defp apply_step(:micro_compact, annotated, system_msgs, _target) do
    total = length(annotated)

    # Find indices of tool result messages (role == "tool")
    tool_indices =
      annotated
      |> Enum.with_index()
      |> Enum.filter(fn {{msg, _imp}, _idx} ->
        safe_to_string(Map.get(msg, :role)) == "tool"
      end)
      |> Enum.map(fn {_, idx} -> idx end)

    # Keep the last @micro_compact_keep tool results intact
    truncate_indices =
      if length(tool_indices) > @micro_compact_keep do
        Enum.drop(tool_indices, -@micro_compact_keep) |> MapSet.new()
      else
        MapSet.new()
      end

    if MapSet.size(truncate_indices) == 0 do
      {annotated, system_msgs, :micro_compact}
    else
      compacted =
        annotated
        |> Enum.with_index()
        |> Enum.map(fn {{msg, imp}, idx} ->
          if idx in truncate_indices do
            content = safe_to_string(Map.get(msg, :content))
            tool_name = Map.get(msg, :name, Map.get(msg, :tool_call_id, "tool"))
            preview = String.slice(content, 0, 100)

            truncated_content =
              "[#{tool_name} result — #{preview}#{if String.length(content) > 100, do: "...", else: ""} (truncated)]"

            {Map.put(msg, :content, truncated_content), imp * 0.5}
          else
            {msg, imp}
          end
        end)

      {compacted, system_msgs, :micro_compact}
    end
  end

  # Step 1: Strip tool-call argument details, keep name + result only
  @doc false
  defp apply_step(:strip_tool_args, annotated, system_msgs, _target) do
    stripped =
      Enum.map(annotated, fn {msg, importance} ->
        msg = strip_tool_args_from_msg(msg)
        {msg, importance}
      end)

    {stripped, system_msgs, :strip_tool_args}
  end

  # Step 2: Merge consecutive same-role messages
  defp apply_step(:merge_consecutive, annotated, system_msgs, _target) do
    merged = merge_consecutive_same_role(annotated)
    {merged, system_msgs, :merge_consecutive}
  end

  # Step 3: Summarize warm-zone messages in groups of 5
  defp apply_step(:summarize_warm, annotated, system_msgs, _target) do
    total = length(annotated)

    if total <= @hot_zone_size do
      # Everything is hot — nothing to summarize
      {annotated, system_msgs, :summarize_warm}
    else
      hot_start = max(total - @hot_zone_size, 0)
      warm_start = max(total - @warm_zone_end, 0)

      cold = Enum.slice(annotated, 0, warm_start)
      warm = Enum.slice(annotated, warm_start, hot_start - warm_start)
      hot = Enum.slice(annotated, hot_start, @hot_zone_size)

      # Sort warm by importance — summarize the least important first
      sorted_warm =
        warm
        |> Enum.with_index()
        |> Enum.sort_by(fn {{_msg, importance}, _idx} -> importance end, :asc)

      # Summarize in groups of 5, starting with least important
      summarized_warm = summarize_in_groups(sorted_warm, 5)

      # Restore original order for the surviving messages
      restored_warm =
        summarized_warm
        |> Enum.sort_by(fn
          {{_msg, _imp}, idx} -> idx
          {msg, _imp} -> Map.get(msg, :__order, 999_999)
        end)
        |> Enum.map(fn
          {{msg, imp}, _idx} -> {msg, imp}
          {msg, imp} -> {msg, imp}
        end)

      {cold ++ restored_warm ++ hot, system_msgs, :summarize_warm}
    end
  end

  # Step 4: Compress cold zone to key facts
  defp apply_step(:compress_cold, annotated, system_msgs, _target) do
    total = length(annotated)
    cold_end = max(total - @warm_zone_end, 0)

    if cold_end <= 0 do
      {annotated, system_msgs, :compress_cold}
    else
      cold = Enum.slice(annotated, 0, cold_end)
      rest = Enum.slice(annotated, cold_end, total - cold_end)

      cold_messages = strip_annotations(cold)

      case call_key_facts_llm(cold_messages) do
        {:ok, summary} ->
          summary_entry = {%{role: "system", content: "[Context Summary]\n#{summary}"}, 2.0}
          {[summary_entry | rest], system_msgs, :compress_cold}

        {:error, reason} ->
          Logger.warning("Compactor cold-zone LLM summarization failed: #{inspect(reason)}")
          # Fall through to emergency truncate
          {annotated, system_msgs, :compress_cold}
      end
    end
  end

  # Step 5: Emergency truncate — no LLM call
  defp apply_step(:emergency_truncate, annotated, system_msgs, _target) do
    total = length(annotated)

    if total <= @hot_zone_size do
      {annotated, system_msgs, :emergency_truncate}
    else
      dropped = Enum.slice(annotated, 0, total - @hot_zone_size)
      kept = Enum.slice(annotated, total - @hot_zone_size, @hot_zone_size)

      topic_notice = %{
        role: "system",
        content:
          "[Context truncated due to length. Earlier conversation was about: #{extract_topics(strip_annotations(dropped))}]"
      }

      updated_system = system_msgs ++ [topic_notice]
      {kept, updated_system, :emergency_truncate}
    end
  end

  # ---------------------------------------------------------------------------
  # Importance scoring
  # ---------------------------------------------------------------------------

  @doc false
  defp annotate_importance(messages) do
    Enum.map(messages, fn msg ->
      {msg, message_importance(msg)}
    end)
  end

  @doc false
  defp message_importance(msg) do
    base = 1.0

    # Tool calls present → +50% retention bonus
    tool_bonus =
      case Map.get(msg, :tool_calls) do
        nil -> 0.0
        [] -> 0.0
        calls when is_list(calls) and length(calls) > 0 -> 0.5
        _ -> 0.0
      end

    # Tool results are also valuable
    tool_result_bonus =
      if safe_to_string(Map.get(msg, :role)) == "tool", do: 0.3, else: 0.0

    # Length / substance bonus (capped at 0.3)
    content = safe_to_string(Map.get(msg, :content))
    length_bonus = min(String.length(content) / 500, 0.3)

    # Acknowledgment penalty
    ack_penalty =
      if Regex.match?(@ack_patterns, content), do: -0.5, else: 0.0

    max(base + tool_bonus + tool_result_bonus + length_bonus + ack_penalty, 0.1)
  end

  @doc false
  defp strip_annotations(annotated) do
    Enum.map(annotated, fn
      {msg, _importance} -> msg
      msg when is_map(msg) -> msg
    end)
  end

  # ---------------------------------------------------------------------------
  # Step 1 helpers: strip tool call args
  # ---------------------------------------------------------------------------

  @doc false
  defp strip_tool_args_from_msg(msg) do
    case Map.get(msg, :tool_calls) do
      nil ->
        msg

      [] ->
        msg

      calls when is_list(calls) ->
        stripped_calls =
          Enum.map(calls, fn tc ->
            # Keep name, id, strip heavy arguments — replace with a placeholder
            tc
            |> Map.put(:arguments, "[args stripped]")
          end)

        Map.put(msg, :tool_calls, stripped_calls)

      _ ->
        msg
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2 helpers: merge consecutive same-role messages
  # ---------------------------------------------------------------------------

  @doc false
  defp merge_consecutive_same_role([]), do: []

  defp merge_consecutive_same_role(annotated) do
    annotated
    |> Enum.reduce([], fn {msg, importance}, acc ->
      case acc do
        [{prev_msg, prev_imp} | rest]
        when is_map(prev_msg) and is_map(msg) ->
          prev_role = safe_to_string(Map.get(prev_msg, :role))
          curr_role = safe_to_string(Map.get(msg, :role))

          # Only merge user-user or assistant-assistant (not tool, not system)
          can_merge =
            prev_role == curr_role and
              prev_role in ["user", "assistant"] and
              not Map.has_key?(prev_msg, :tool_calls) and
              not Map.has_key?(msg, :tool_calls) and
              not Map.has_key?(prev_msg, :tool_call_id) and
              not Map.has_key?(msg, :tool_call_id)

          if can_merge do
            merged_content =
              safe_to_string(Map.get(prev_msg, :content)) <>
                "\n" <>
                safe_to_string(Map.get(msg, :content))

            merged_msg = Map.put(prev_msg, :content, merged_content)
            merged_imp = max(prev_imp, importance)
            [{merged_msg, merged_imp} | rest]
          else
            [{msg, importance} | acc]
          end

        _ ->
          [{msg, importance} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Step 3 helpers: summarize in groups
  # ---------------------------------------------------------------------------

  @doc false
  defp summarize_in_groups(indexed_annotated, group_size) do
    # indexed_annotated is [{msg_with_importance, original_index}, ...]
    # Group and summarize the lowest-importance ones
    groups = Enum.chunk_every(indexed_annotated, group_size)

    Enum.flat_map(groups, fn group ->
      messages = Enum.map(group, fn {{msg, _imp}, _idx} -> msg end)
      group_tokens = estimate_tokens(messages)

      # Only summarize if the group is substantial enough to benefit
      if group_tokens > 200 do
        case call_summary_llm(messages) do
          {:ok, summary} ->
            # Replace the group with a single summary message
            summary_msg = %{
              role: "system",
              content: "[Warm Summary]\n#{summary}",
              __order: elem(List.first(group), 1)
            }

            [{summary_msg, 1.5}]

          {:error, _reason} ->
            # Keep originals on LLM failure
            Enum.map(group, fn {{msg, imp}, _idx} -> {msg, imp} end)
        end
      else
        Enum.map(group, fn {{msg, imp}, _idx} -> {msg, imp} end)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # LLM helpers
  # ---------------------------------------------------------------------------

  @summary_prompt_fallback """
  Summarize the following conversation excerpt concisely. Preserve:
  - All file paths and line numbers mentioned
  - All error messages and their causes
  - All decisions made and their reasoning
  - All specific values, variable names, and config settings
  - Tool names used and their key results
  Be terse — use bullet points. Never lose concrete details.

  %MESSAGES%
  """

  @doc false
  defp call_summary_llm(messages_to_summarize) do
    if not compactor_llm_enabled?() do
      # Stub: return a placeholder summary when LLM is disabled (test env)
      {:ok, "[Summary of #{length(messages_to_summarize)} messages]"}
    else
      template = PromptLoader.get(:compactor_summary, @summary_prompt_fallback)
      formatted = format_for_summary(messages_to_summarize)

      prompt =
        if String.contains?(template, "%MESSAGES%") do
          String.replace(template, "%MESSAGES%", formatted)
        else
          template <> "\n\n" <> formatted
        end

      prompt = append_compact_instructions(prompt)

      try do
        Providers.chat([%{role: "user", content: prompt}], temperature: 0.2, max_tokens: 400)
        |> case do
          {:ok, %{content: content}} when is_binary(content) and content != "" ->
            {:ok, content}

          {:ok, %{content: content}} ->
            {:error, "Empty summary: #{inspect(content)}"}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e ->
          {:error, "LLM call exception: #{Exception.message(e)}"}
      end
    end
  end

  @structured_compression_template """
  You are compressing a conversation to fit within a context window.
  Maintain a structured summary with these EXACT 8 sections. Output ONLY these sections.

  ## Goal
  What is the user trying to accomplish? What's the end state?

  ## Constraints
  Requirements, limitations, rules the user specified.

  ## Progress
  What has been done so far? Key milestones reached.

  ## Key Decisions
  Important choices made and WHY they were made.

  ## Relevant Files
  File paths that have been read, modified, or are important.
  Include line numbers for specific locations discussed.

  ## Errors & Issues
  Any errors encountered, their causes, and resolutions.

  ## Next Steps
  What still needs to be done. Ordered by priority.

  ## Working Memory
  Specific values, variable names, config settings, URLs, or other
  concrete details that must be preserved exactly.

  IMPORTANT:
  - Preserve ALL file paths, error messages, and specific values exactly
  - Update sections incrementally — do not start over if a previous summary exists
  - If a previous summary exists, MERGE new info into existing sections
  - Keep the summary concise but complete

  %PREVIOUS_SUMMARY%

  NEW CONVERSATION TURNS TO INTEGRATE:
  %MESSAGES%
  """

  @doc false
  defp call_key_facts_llm(messages_to_compress) do
    if not compactor_llm_enabled?() do
      {:ok, "[Key facts from #{length(messages_to_compress)} messages]"}
    else
      formatted = format_for_summary(messages_to_compress)

      # Retrieve previous structured summary for iterative merge
      previous_summary = get_previous_summary()

      prompt =
        if previous_summary do
          # Use structured template for iterative compression
          @structured_compression_template
          |> String.replace(
            "%PREVIOUS_SUMMARY%",
            "PREVIOUS SUMMARY (merge new info into this):\n#{previous_summary}"
          )
          |> String.replace("%MESSAGES%", formatted)
        else
          # First compression — use structured template without previous summary
          @structured_compression_template
          |> String.replace(
            "%PREVIOUS_SUMMARY%",
            "PREVIOUS SUMMARY: None — this is the first compression."
          )
          |> String.replace("%MESSAGES%", formatted)
        end

      # PreCompact hook instructions (CC parity): custom_instructions from the
      # PreCompact hook are appended to the key-facts prompt as well.
      prompt = append_compact_instructions(prompt)

      try do
        Providers.chat([%{role: "user", content: prompt}], temperature: 0.1, max_tokens: 1024)
        |> case do
          {:ok, %{content: content}} when is_binary(content) and content != "" ->
            # Store the structured summary for future compressions
            store_previous_summary(content)
            {:ok, content}

          {:ok, %{content: content}} ->
            {:error, "Empty key-facts response: #{inspect(content)}"}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e ->
          {:error, "LLM call exception: #{Exception.message(e)}"}
      end
    end
  end

  # ── Structured Summary Persistence (ETS) ─────────────────────────────

  @doc false
  defp get_previous_summary do
    try do
      case :ets.lookup(:osa_compactor_state, :previous_summary) do
        [{:previous_summary, summary}] -> summary
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc false
  defp store_previous_summary(summary) do
    try do
      :ets.insert(:osa_compactor_state, {:previous_summary, summary})
      :ets.insert(:osa_compactor_state, {:last_summary_at, DateTime.utc_now()})
    rescue
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  defp split_system(messages) do
    Enum.split_with(messages, fn msg ->
      safe_to_string(Map.get(msg, :role)) == "system"
    end)
  end

  @doc false
  defp format_for_summary(messages) do
    messages
    |> Enum.map(fn msg ->
      role = safe_to_string(Map.get(msg, :role, "unknown"))
      content = safe_to_string(Map.get(msg, :content))

      tool_info =
        case Map.get(msg, :tool_calls) do
          nil ->
            ""

          [] ->
            ""

          calls when is_list(calls) ->
            names = Enum.map(calls, &safe_to_string(Map.get(&1, :name, "?"))) |> Enum.join(", ")
            " [tools: #{names}]"

          _ ->
            ""
        end

      "#{role}#{tool_info}: #{content}"
    end)
    |> Enum.join("\n")
  end

  @doc false
  defp extract_topics(messages) do
    messages
    |> Enum.filter(fn msg -> safe_to_string(Map.get(msg, :role)) == "user" end)
    |> Enum.map(fn msg ->
      content = safe_to_string(Map.get(msg, :content))
      String.slice(content, 0, 100)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
    |> String.slice(0, 500)
  end

  @doc false
  defp record_compaction(tokens_saved, step) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:record_compaction, tokens_saved, step})
    end
  end

  @doc false
  defp pct(ratio), do: "#{Float.round(ratio * 100, 1)}%"

  defp safe_to_string(val),
    do: OptimalSystemAgent.Utils.Text.safe_to_string(val)

  # Append PreCompact hook instructions (set per-run in the process dict by
  # run_pipeline) to a summarization prompt.
  defp append_compact_instructions(prompt) do
    case Process.get(:osa_compact_instructions) do
      instr when is_binary(instr) and instr != "" ->
        prompt <>
          "\n\nAdditional instructions for this summary (from PreCompact hook):\n" <> instr

      _ ->
        prompt
    end
  end

  defp compactor_llm_enabled? do
    Application.get_env(:optimal_system_agent, :compactor_llm_enabled, true)
  end
end
