defmodule OptimalSystemAgent.Agent.Loop.DoomLoop do
  require Logger

  alias OptimalSystemAgent.Events.Bus

  @window_size 20

  @max_total_tool_calls Application.compile_env(
                          :optimal_system_agent,
                          :doom_loop_max_calls,
                          100
                        )

  @warn_threshold_pct 0.80

  # Graded escalation: before any hard halt, the agent is nudged to CHANGE
  # APPROACH. Each distinct "approaching" signal advances one step in a shared
  # per-session sequence (reflect -> try something different -> decompose).
  # After the steps are exhausted, control falls through to the existing hard
  # halts (identical-call cap, repeated-failure recovery, or the stall halt).
  @max_graded_escalations 3

  # Stall detection: if the last N tool calls introduce no newly-distinct tool
  # and perform no file write/edit, the agent is spinning without progress.
  @stall_window_size 6

  # Tools that represent forward progress on the workspace (a write or edit).
  @write_edit_tools ~w(file_write file_edit file_create write_file edit_file
                       apply_patch str_replace str_replace_editor create_file
                       file_append multi_edit)

  @moduledoc """
  Doom loop detection for the agent loop.

  Two independent safety mechanisms guard against runaway tool execution:

  1. **Signature-based detection** (primary) — detects when the same
     tool+error signature repeats 3+ consecutive times across iterations
     and halts execution to avoid wasting tokens on a stuck task.

     - Builds per-tool failure signatures from each iteration's results
     - Accumulates signatures in a sliding window of #{@window_size} entries
     - Resets the error-based streak when any tool succeeds cleanly
     - Fires when any single signature appears 3+ times in the window

  2. **Absolute call cap** (secondary safety net) — independently of the
     signature check, halts the session once total tool calls in the session
     exceed `@max_total_tool_calls`. This prevents a pathological worst-case
     where many *different* failure signatures accumulate without repeating
     enough to trigger the primary check.

     Configurable via: `config :optimal_system_agent, :doom_loop_max_calls, 100`
     A warning is logged at 80% of the limit.
  """

  @error_indicators ~w(error Error failed not found command not found
                       No such file Permission denied cannot Could not
                       Blocked: invalid syntax unexpected)

  @doc """
  Check tool results for a repeating failure pattern.

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  @spec check(list(), list(), map()) ::
          {:ok, map()} | {:halt, String.t(), map()}
  def check(results, tool_calls, state) do
    # At most one graded directive is injected per invocation; reset the
    # per-tick guard so multiple approaching signals don't stack directives.
    Process.delete(:osa_escalated_this_tick)

    # --- Absolute call counter (secondary safety net) ---
    call_count = length(tool_calls)
    new_total = Map.get(state, :total_tool_calls, 0) + call_count
    state = %{state | total_tool_calls: new_total}

    warn_at = trunc(@max_total_tool_calls * @warn_threshold_pct)

    # --- Identical-call detection ---
    # Catches the model spamming the same tool+args back-to-back even when
    # the calls succeed (model ignores the result and re-issues). The
    # signature-based check below only catches repeated FAILURES; this
    # catches repeated USELESS SUCCESSES (e.g. dir_list of cwd 6× in a row).
    with {:ok, state} <- check_repeat_calls(tool_calls, state),
         # --- Stall detection ---
         # No newly-distinct tool and no file write/edit over the last N calls.
         {:ok, state} <- check_stall(tool_calls, state) do
      cond do
        new_total >= @max_total_tool_calls ->
          handle_call_cap_exceeded(new_total, state)

        new_total >= warn_at and new_total - call_count < warn_at ->
          Logger.warning(
            "[doom] Approaching tool call limit (#{new_total}/#{@max_total_tool_calls}) " <>
              "(session: #{state.session_id})"
          )

          check_signatures(results, tool_calls, state)

        true ->
          check_signatures(results, tool_calls, state)
      end
    else
      {:halt, _, _} = halted -> halted
    end
  end

  # Tracks the last N tool invocations as `{name, args_hash}` tuples and
  # halts when 4+ consecutive entries are identical. Independent of success
  # vs. error — protects against the model looping on a working tool when
  # it isn't using the result.
  @repeat_threshold 4
  @repeat_window 8

  defp check_repeat_calls(tool_calls, state) do
    new_keys =
      Enum.map(tool_calls, fn tc ->
        args =
          case Map.get(tc, :arguments) do
            m when is_map(m) -> m
            _ -> %{}
          end

        {tc.name, :erlang.phash2(args)}
      end)

    history =
      (Map.get(state, :recent_call_keys, []) ++ new_keys)
      |> Enum.take(-@repeat_window)

    state = Map.put(state, :recent_call_keys, history)

    streak =
      history
      |> Enum.reverse()
      |> Enum.chunk_while(
        nil,
        fn key, acc ->
          cond do
            is_nil(acc) -> {:cont, {key, 1}}
            elem(acc, 0) == key -> {:cont, {key, elem(acc, 1) + 1}}
            true -> {:halt, acc}
          end
        end,
        fn acc -> {:cont, acc, nil} end
      )
      |> List.first()

    case streak do
      {{tool, _hash}, n} when n >= @repeat_threshold ->
        msg =
          "Stopped: tool `#{tool}` was called with identical arguments #{n} times in a row " <>
            "without making progress. The result of an earlier call is already in context — " <>
            "use it, or try a different tool / different arguments."

        Logger.warning("[doom] Identical-call loop on #{tool} (#{n}x) — halting")

        Bus.emit(:doom_loop_halt, %{
          session_id: state.session_id,
          reason: :identical_repeat,
          tool: tool,
          repeats: n
        })

        {:halt, msg, state}

      {{tool, _hash}, n} when n == @repeat_threshold - 1 ->
        # One below the hard identical-call cap: nudge a change of approach
        # before the next repeat triggers the halt above.
        graded_escalation(
          :approaching_identical_repeat,
          "You have called `#{tool}` with identical arguments #{n} times in a row.",
          state
        )

      _ ->
        {:ok, state}
    end
  end

  # --- Private ---

  defp check_signatures(results, tool_calls, state) do
    iteration_signatures = collect_iteration_signatures(results, tool_calls)

    any_clean_success =
      Enum.any?(results, fn {_tc, {_msg, result_str}} ->
        not Enum.any?(@error_indicators, fn ind -> String.contains?(result_str, ind) end)
      end)

    # When any tool succeeded cleanly this iteration, reset error signatures.
    # Pattern-based detection (file rewrites) was removed — caused 4+ false positives.
    new_sigs =
      if any_clean_success do
        []
      else
        Enum.map(iteration_signatures, fn {sig, _name, _err} -> sig end)
      end

    Logger.debug("[doom] Checking #{length(results)} tool results for doom patterns")

    Logger.debug(
      "[doom] Signatures this iteration: #{inspect(Enum.map(iteration_signatures, fn {sig, _, _} -> sig end))}"
    )

    Logger.debug("[doom] Total accumulated: #{inspect(state.recent_failure_signatures)}")

    updated_failure_signatures =
      (state.recent_failure_signatures ++ new_sigs)
      |> Enum.take(-@window_size)

    state = %{state | recent_failure_signatures: updated_failure_signatures}

    grouped = Enum.group_by(updated_failure_signatures, & &1)

    repeated_signature =
      Enum.find(grouped, fn {_sig, occurrences} -> length(occurrences) >= 3 end)

    approaching_signature =
      Enum.find(grouped, fn {_sig, occurrences} -> length(occurrences) == 2 end)

    cond do
      repeated_signature ->
        handle_doom_loop(repeated_signature, iteration_signatures, state)

      approaching_signature ->
        # Same failure signature seen twice — one short of the hard recovery
        # threshold. Nudge a change of approach before it repeats a third time.
        {sig, _occurrences} = approaching_signature

        graded_escalation(
          :approaching_repeated_failure,
          "The same failure keeps recurring (signature: #{sig}).",
          state
        )

      true ->
        {:ok, state}
    end
  end

  defp collect_iteration_signatures(results, _tool_calls) do
    Enum.flat_map(results, fn {tc, {_msg, result_str}} ->
      is_error =
        Enum.any?(@error_indicators, fn indicator ->
          String.contains?(result_str, indicator)
        end)

      if is_error do
        error_prefix =
          result_str
          |> String.slice(0, 100)
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        [{"#{tc.name}:#{error_prefix}", tc.name, error_prefix}]
      else
        []
      end
    end)
  end

  defp handle_call_cap_exceeded(total, state) do
    cap_message =
      """
      I've reached the session tool call limit (#{total}/#{@max_total_tool_calls}) and am stopping to avoid runaway execution.

      This limit exists as a safety net independent of error-pattern detection.

      How to proceed:
      - If the task is incomplete, start a new session and continue from where you left off.
      - If you need a higher limit, adjust `doom_loop_max_calls` in your application config.
      """
      |> String.trim()

    Logger.warning(
      "[loop] Tool call cap exceeded: #{total}/#{@max_total_tool_calls} (session: #{state.session_id})"
    )

    Bus.emit(:system_event, %{
      event: :tool_call_cap_exceeded,
      session_id: state.session_id,
      total_tool_calls: total,
      max_tool_calls: @max_total_tool_calls
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :tool_call_cap_exceeded,
         session_id: state.session_id,
         total_tool_calls: total,
         max_tool_calls: @max_total_tool_calls
       }}
    )

    {:halt, cap_message, state}
  end

  defp handle_doom_loop({repeated_sig_key, occurrences}, iteration_signatures, state) do
    repeat_count = length(occurrences)

    {triggering_tool, triggering_error} =
      case Enum.find(iteration_signatures, fn {sig, _n, _e} -> sig == repeated_sig_key end) do
        {_sig, name, err} ->
          {name, err}

        nil ->
          case String.split(repeated_sig_key, ":", parts: 2) do
            [name, err] -> {name, err}
            _ -> {"unknown", repeated_sig_key}
          end
      end

    suggestion = build_suggestion(triggering_error)

    doom_message =
      """
      I hit the same error #{repeat_count} times with #{triggering_tool}: #{triggering_error}

      #{suggestion}
      """
      |> String.trim()

    Logger.warning(
      "[loop] Doom loop detected: #{repeated_sig_key} repeated #{repeat_count} times (session: #{state.session_id})"
    )

    Bus.emit(:system_event, %{
      event: :doom_loop_detected,
      session_id: state.session_id,
      tool_name: triggering_tool,
      error_prefix: triggering_error,
      signature: repeated_sig_key,
      consecutive_failures: repeat_count
    })

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :doom_loop_detected,
         session_id: state.session_id,
         tool_name: triggering_tool,
         error_prefix: triggering_error,
         signature: repeated_sig_key,
         consecutive_failures: repeat_count
       }}
    )

    # Track how many times we've tried recovery for this session
    doom_recovery_count = Process.get(:osa_doom_recovery_count, 0)

    if doom_recovery_count >= 2 do
      # Already tried recovery twice — hard halt this time
      {:halt, doom_message, state}
    else
      # First or second doom trigger — inject recovery directive and try again
      Logger.info("[doom] Recovery attempt #{doom_recovery_count + 1}/2 — injecting directive")

      recovery_directive = %{
        role: "system",
        content:
          "[DOOM LOOP RECOVERY: You tried #{triggering_tool} #{repeat_count} times with the same error: " <>
            "\"#{triggering_error}\". You MUST change your approach NOW. " <>
            "Step 1: Call file_read on the target file to see its current state. " <>
            "Step 2: Based on what you see, decide if the change is still needed. " <>
            "Step 3: If yes, use COMPLETELY DIFFERENT arguments. If no, move on. " <>
            "Do NOT call #{triggering_tool} with the same arguments again.]"
      }

      Process.put(:osa_doom_recovery_count, doom_recovery_count + 1)

      state = %{
        state
        | recent_failure_signatures: [],
          messages: state.messages ++ [recovery_directive]
      }

      {:ok, state}
    end
  end

  defp build_suggestion(triggering_error) do
    cond do
      String.contains?(triggering_error, "old_string and new_string are identical") ->
        "The file already contains the change you're trying to make. " <>
          "Read the file with file_read to see its current state, then decide if the edit is still needed."

      String.contains?(triggering_error, "old_string not found") ->
        "The text you're trying to replace doesn't exist in the file. " <>
          "Read the file with file_read to see the actual content, then use the exact text from the file."

      String.contains?(triggering_error, "old_string found") and
          String.contains?(triggering_error, "times") ->
        "The text appears multiple times. Add more surrounding context to make old_string unique, " <>
          "or use replace_all: true."

      String.contains?(triggering_error, ["command not found", "not found"]) ->
        "The command or binary does not exist. " <>
          "Check what's installed with shell_execute(command: \"which <tool>\") or use an alternative."

      String.contains?(triggering_error, ["Permission denied", "cannot", "Could not"]) ->
        "Permission denied. Check file permissions or try a different path."

      String.contains?(triggering_error, ["No such file", "No such directory"]) ->
        "File or directory does not exist. " <>
          "Use file_glob or dir_list to find the correct path."

      String.contains?(triggering_error, ["Blocked:"]) ->
        "Tool blocked by permissions. Use a different tool or approach."

      true ->
        "Read the relevant files with file_read to understand the current state, " <>
          "then try a completely different approach. Do NOT retry the same operation."
    end
  end

  # --- Stall detection ---
  #
  # Distinct from the identical-call and failure-signature checks: those catch
  # *repetition*, this catches *non-progress*. If the last `@stall_window_size`
  # tool calls introduced no newly-distinct tool AND performed no file
  # write/edit, the agent is spinning. We emit the graded escalation and only
  # hard-halt once the graded steps are exhausted.
  defp check_stall(tool_calls, state) do
    names = Enum.map(tool_calls, & &1.name)
    seen_before = Map.get(state, :distinct_tools_seen, MapSet.new())

    # Running distinct-tool count after each call this batch, so we can compare
    # "now" against "@stall_window_size calls ago" to detect a newly-seen tool.
    {count_entries, distinct_after} =
      Enum.map_reduce(names, seen_before, fn name, acc ->
        acc = MapSet.put(acc, name)
        {MapSet.size(acc), acc}
      end)

    name_window =
      (Map.get(state, :recent_tool_names, []) ++ names)
      |> Enum.take(-@stall_window_size)

    count_log =
      (Map.get(state, :distinct_count_log, []) ++ count_entries)
      |> Enum.take(-(@stall_window_size + 1))

    state =
      state
      |> Map.put(:distinct_tools_seen, distinct_after)
      |> Map.put(:recent_tool_names, name_window)
      |> Map.put(:distinct_count_log, count_log)

    introduced_new_tool? =
      length(count_log) < @stall_window_size + 1 or
        List.last(count_log) > List.first(count_log)

    wrote_or_edited? = Enum.any?(name_window, &write_or_edit_tool?/1)

    stalled? =
      length(name_window) >= @stall_window_size and
        not introduced_new_tool? and not wrote_or_edited?

    if stalled? do
      case escalate(
             :stall,
             "The last #{@stall_window_size} tool calls made no progress: " <>
               "no new file was written or edited and no new tool was tried.",
             state
           ) do
        {:escalated, state} ->
          {:ok, state}

        {:exhausted, state} ->
          msg =
            "Stopped: no forward progress in the last #{@stall_window_size} tool calls " <>
              "(no file writes/edits, no new approach) despite repeated nudges to change approach. " <>
              "The task appears stuck — reconsider the goal or decompose it into smaller steps."

          Logger.warning("[doom] Stall detected — halting after exhausting graded escalation")

          Bus.emit(:doom_loop_halt, %{
            session_id: state.session_id,
            reason: :stall,
            window: @stall_window_size
          })

          {:halt, msg, state}
      end
    else
      {:ok, state}
    end
  end

  defp write_or_edit_tool?(name) do
    downcased = name |> to_string() |> String.downcase()

    name in @write_edit_tools or
      String.contains?(downcased, "write") or
      String.contains?(downcased, "edit") or
      String.contains?(downcased, "patch")
  end

  # --- Graded escalation ---
  #
  # For "approaching a threshold" callers: nudge the agent, but never halt here
  # (the existing hard halts remain the backstop). Always returns `{:ok, state}`.
  defp graded_escalation(reason, context, state) do
    case escalate(reason, context, state) do
      {:escalated, state} -> {:ok, state}
      {:exhausted, state} -> {:ok, state}
    end
  end

  # Advances the shared per-session graded sequence and injects the next
  # directive into the message history. Returns `{:escalated, state}` while
  # steps remain, or `{:exhausted, state}` once all steps have been used.
  # At most one directive is injected per `check/3` invocation.
  defp escalate(reason, context, state) do
    count = Process.get(:osa_graded_escalation_count, 0)

    cond do
      count >= @max_graded_escalations ->
        {:exhausted, state}

      Process.get(:osa_escalated_this_tick, false) ->
        # A directive was already injected this tick; don't stack another.
        {:escalated, state}

      true ->
        step = count + 1
        Process.put(:osa_graded_escalation_count, step)
        Process.put(:osa_escalated_this_tick, true)

        directive = %{
          role: "system",
          content:
            "[CHANGE APPROACH — graded nudge #{step}/#{@max_graded_escalations}] " <>
              context <> " " <> graded_step_instruction(step)
        }

        Logger.info(
          "[doom] Graded escalation #{step}/#{@max_graded_escalations} (#{reason}) — " <>
            "injecting directive (session: #{state.session_id})"
        )

        Bus.emit(:system_event, %{
          event: :doom_graded_escalation,
          session_id: state.session_id,
          step: step,
          max_steps: @max_graded_escalations,
          reason: reason
        })

        messages = Map.get(state, :messages, [])
        state = Map.put(state, :messages, messages ++ [directive])

        {:escalated, state}
    end
  end

  defp graded_step_instruction(1) do
    "REFLECT before acting: why isn't this working? State the assumption that " <>
      "might be wrong, then act on that insight — do not simply retry."
  end

  defp graded_step_instruction(2) do
    "Reflection wasn't enough. Use a DIFFERENT tool or a fundamentally " <>
      "different approach than the one you have been repeating."
  end

  defp graded_step_instruction(3) do
    "You are still stuck. DECOMPOSE the task into smaller, concrete sub-steps " <>
      "and tackle only the first one, using a different method than before."
  end

  defp graded_step_instruction(_), do: "Change your approach now."
end
