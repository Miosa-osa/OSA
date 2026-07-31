defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature do
  @moduledoc """
  Signature-based failure detector (the primary doom-loop mechanism).

  Builds per-tool failure signatures from each iteration's results, accumulates
  them in a sliding window of 20 entries on the threaded `state`
  (`:recent_failure_signatures`), and resets the error-based streak when any
  tool succeeds cleanly. When a single signature repeats 3+ times it triggers a
  bounded recovery sequence (`:doom_recovery_count`, reset each user turn) that
  injects a recovery directive up to twice before hard-halting. Two occurrences
  (one short of the recovery threshold) delegate to `Escalation` to nudge a
  change of approach.

  Also owns suggestion-text generation (`build_suggestion/1`) — the
  error-specific guidance surfaced when a doom loop is detected.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation
  alias OptimalSystemAgent.Agent.Loop.ToolError

  @window_size 20

  @error_indicators ~w(error Error failed not found command not found
                       No such file Permission denied cannot Could not
                       Blocked: invalid syntax unexpected)

  @doc """
  Check tool results for a repeating failure signature.

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  def check(results, tool_calls, state) do
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

        Escalation.graded(
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
        end) and
          # An OPERATOR decision (permission denial, cancelled/timed-out
          # approval, reject-with-steer) is a model-readable answer, not a stuck
          # tool. Counting it as a failure signature let three declines of the
          # same tool hard-halt the turn — the exact "it won't let me finish"
          # symptom the non-fatal tool error contract exists to remove.
          not ToolError.user_decision?(result_str)

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

    # Track how many times we've tried recovery for this session. The count is
    # threaded on `state` (reset each user turn) rather than the process dict.
    doom_recovery_count = Map.get(state, :doom_recovery_count, 0)

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

      state = %{
        state
        | recent_failure_signatures: [],
          messages: state.messages ++ [recovery_directive],
          doom_recovery_count: doom_recovery_count + 1
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
