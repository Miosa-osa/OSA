defmodule OptimalSystemAgent.Agent.Loop.DoomLoop do
  @moduledoc """
  Doom loop detection for the agent loop.

  Detects when the same tool+error signature repeats 3+ consecutive times
  across iterations and halts execution to avoid wasting tokens on a stuck task.

  The detection algorithm:
  - Builds per-tool failure signatures from each iteration's results
  - Accumulates signatures in a sliding window of 30 entries
  - Resets the error-based streak when any tool succeeds cleanly
  - Fires when any single signature appears 3+ times in the window
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus

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
    Logger.debug("[doom] Signatures this iteration: #{inspect(Enum.map(iteration_signatures, fn {sig, _, _} -> sig end))}")
    Logger.debug("[doom] Total accumulated: #{inspect(state.recent_failure_signatures)}")

    updated_failure_signatures =
      (state.recent_failure_signatures ++ new_sigs)
      |> Enum.take(-30)

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

  # --- Private ---

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
      I've hit the same error #{repeat_count} times and I'm stopping to avoid wasting tokens.

      What I tried:
      - #{triggering_tool}: called #{repeat_count} times with the same failing result

      Error pattern:
      - #{triggering_error}

      How to proceed:
      - #{suggestion}
      """
      |> String.trim()

    Logger.warning("[loop] Doom loop detected: #{repeated_sig_key} repeated #{repeat_count} times (session: #{state.session_id})")

    Bus.emit(:system_event, %{
      event: :doom_loop_detected,
      session_id: state.session_id,
      tool_name: triggering_tool,
      error_prefix: triggering_error,
      signature: repeated_sig_key,
      consecutive_failures: repeat_count
    })

    Phoenix.PubSub.broadcast(OptimalSystemAgent.PubSub, "osa:session:#{state.session_id}",
      {:osa_event, %{
        type: :doom_loop_detected,
        session_id: state.session_id,
        tool_name: triggering_tool,
        error_prefix: triggering_error,
        signature: repeated_sig_key,
        consecutive_failures: repeat_count
      }})

    {:halt, doom_message, state}
  end

  defp build_suggestion(triggering_error) do
    cond do
      String.contains?(triggering_error, ["command not found", "not found"]) ->
        "The command or binary does not exist in this environment. " <>
          "Verify the tool is installed or use an alternative approach."

      String.contains?(triggering_error, ["Permission denied", "cannot", "Could not"]) ->
        "This operation requires elevated permissions or the target path is inaccessible. " <>
          "Check file permissions or try a different path."

      String.contains?(triggering_error, ["No such file", "No such directory"]) ->
        "The referenced file or directory does not exist. " <>
          "Confirm the correct path before retrying."

      String.contains?(triggering_error, ["Blocked:"]) ->
        "The tool is blocked by the current permission tier. " <>
          "Request a permission level change or use an allowed alternative."

      true ->
        "Review the error above, adjust your approach, and try a different strategy " <>
          "before retrying the same operation."
    end
  end
end
