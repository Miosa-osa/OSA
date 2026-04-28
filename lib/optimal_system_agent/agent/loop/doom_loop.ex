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
    # --- Absolute call counter (secondary safety net) ---
    call_count = length(tool_calls)
    new_total = Map.get(state, :total_tool_calls, 0) + call_count
    state = %{state | total_tool_calls: new_total}

    warn_at = trunc(@max_total_tool_calls * @warn_threshold_pct)

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

    repeated_signature =
      updated_failure_signatures
      |> Enum.group_by(& &1)
      |> Enum.find(fn {_sig, occurrences} -> length(occurrences) >= 3 end)

    if repeated_signature do
      handle_doom_loop(repeated_signature, iteration_signatures, state)
    else
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
end
