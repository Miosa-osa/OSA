defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.FailureSignature do
  @moduledoc """
  Signature-based failure detector (the primary doom-loop mechanism).

  ## What counts as a loop

  A loop is **the same action producing the same result with no state change**.
  Concretely, for this detector, an entry only accumulates when BOTH hold:

    1. the tool call actually **failed** — the model-facing body carries the
       `"Error:"` / `"Blocked:"` prefix that
       `ToolError.model_text/1` guarantees for every non-fatal failure (see
       `ToolError`), and the failure is not an operator decision; and
    2. the **identical arguments** were used — the signature keys on a digest of
       the tool arguments, so two calls that differ in any argument are two
       different signatures.

  Repeated *successful* edits to one file — five different `@impl` annotations
  added to `compactor.ex`, say — are PROGRESS. They can no longer accumulate a
  signature, because each edit succeeds (rule 1) and each carries different
  arguments (rule 2).

  ### Regression history (why the rules above are phrased that way)

  The pre-fix detector classified a result as a failure by scanning the WHOLE
  result body for substrings like `"error"`, `"cannot"`, `"failed"`,
  `"not found"`. A successful `file_edit` result embeds a unified diff of the
  edited file, so any source file that merely *mentions* an error (virtually
  every file) made its own successful edit look like a failure. It then
  truncated the signature to the first 100 characters — which for a `file_edit`
  is `"Replaced in <path>\\n--- <path…"`, i.e. **identical for every edit to the
  same file regardless of content**. Three successful edits to one file
  therefore read as "the same failure three times" and tripped recovery. The
  agent read the nudge and abandoned correct work mid-task. Both causes are
  fixed: outcome is contract-based, and the signature includes an args digest.

  ## Thresholds

  Signatures accumulate in a sliding window of 20 entries on the threaded
  `state` (`:recent_failure_signatures`); a cleanly-succeeding tool clears only
  the failure signatures for THAT SAME tool, so one interleaved success (a
  `file_read`, say) can no longer starve the accumulator while a different
  tool keeps failing. A *strict* signature (tool + args digest + error
  prefix) repeating 3+ times triggers a bounded recovery sequence
  (`:doom_recovery_count`, reset each user turn) that injects a recovery
  directive up to twice before hard-halting. Two occurrences (one short of the
  recovery threshold) delegate to `Escalation` to nudge a change of approach.

  A *broad* signature (tool + error prefix, arguments ignored) is also tracked
  as a backstop for a model that keeps failing the same way while jittering its
  arguments; it needs twice as many repeats (6) before it triggers the same
  recovery sequence.

  Also owns suggestion-text generation (`build_suggestion/1`) — the
  error-specific guidance surfaced when a doom loop is detected.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation
  alias OptimalSystemAgent.Agent.Loop.ToolError

  @window_size 20

  # Repeats of the STRICT signature (tool + identical args + same error) before
  # recovery fires. This is the "same action, same result, no state change"
  # definition of a loop.
  @strict_threshold 3

  # Repeats of the BROAD signature (tool + same error, arguments ignored).
  # Deliberately looser AND slower: it exists so a model that keeps failing
  # identically while jittering one argument still gets caught, without letting
  # "same tool, same file" alone imply a loop.
  @broad_threshold 6

  # Legacy heuristic, retained ONLY as a fallback for a tool that returns error
  # text without the `Error:`/`Blocked:` prefix. Matched against the FIRST LINE
  # of the result only — never against the body, which for a write/edit tool
  # contains file content and would otherwise make every successful edit to a
  # real source file look like a failure.
  @error_indicators ~w(error Error failed not found command not found
                       No such file Permission denied cannot Could not
                       Blocked: invalid syntax unexpected)

  @doc """
  Check tool results for a repeating failure signature.

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  def check(results, tool_calls, state) do
    iteration_signatures = collect_iteration_signatures(results, tool_calls)

    # Tools that produced at least one clean (non-failure) result this iteration.
    # A clean success is progress FOR THAT TOOL, so it clears that tool's failure
    # signatures below — but ONLY that tool's (P1-8). Previously ANY clean
    # success dropped the whole iteration's new sigs, so a single interleaved
    # file_read success starved the accumulator and a real failing-edit loop
    # never reached the threshold.
    succeeded_tools =
      results
      |> Enum.filter(fn {_tc, {_msg, result_str}} -> not failure?(result_str) end)
      |> Enum.map(fn {tc, _} -> tc.name end)
      |> MapSet.new()

    # Always accumulate this iteration's failure signatures; the same-tool clear
    # below removes only what a matching success invalidated. Pattern-based
    # detection (file rewrites) was removed — caused 4+ false positives.
    new_sigs = Enum.map(iteration_signatures, fn entry -> {entry.strict, entry.broad} end)

    Logger.debug("[doom] Checking #{length(results)} tool results for doom patterns")

    Logger.debug(
      "[doom] Signatures this iteration: #{inspect(Enum.map(iteration_signatures, & &1.strict))}"
    )

    Logger.debug("[doom] Total accumulated: #{inspect(state.recent_failure_signatures)}")

    updated_failure_signatures =
      (state.recent_failure_signatures ++ new_sigs)
      |> Enum.reject(fn sig -> MapSet.member?(succeeded_tools, sig_tool(sig)) end)
      |> Enum.take(-@window_size)

    state = %{state | recent_failure_signatures: updated_failure_signatures}

    strict_counts = tally(updated_failure_signatures, 0)
    broad_counts = tally(updated_failure_signatures, 1)

    repeated =
      Enum.find(strict_counts, fn {_sig, n} -> n >= @strict_threshold end) ||
        Enum.find(broad_counts, fn {_sig, n} -> n >= @broad_threshold end)

    approaching =
      Enum.find(strict_counts, fn {_sig, n} -> n == @strict_threshold - 1 end)

    cond do
      repeated ->
        handle_doom_loop(repeated, iteration_signatures, state)

      approaching ->
        # Same *identical* failing call seen twice — one short of the hard
        # recovery threshold. Nudge a change of approach for THAT CALL before it
        # repeats a third time. The wording is deliberately scoped to the one
        # repeated failing call: a nudge must never read as "abandon this task".
        {sig, _n} = approaching

        Escalation.graded(
          :approaching_repeated_failure,
          scoped_context(tool_for(sig, iteration_signatures)),
          state
        )

      true ->
        {:ok, state}
    end
  end

  # Tool name a stored signature belongs to: the segment before the first ":"
  # in the strict/broad string (`"#{tc.name}:..."`). Tolerates the {strict,
  # broad} tuple and the legacy bare-string entry of a resumed session.
  defp sig_tool(sig) do
    strict =
      case sig do
        {strict, _broad} -> strict
        other -> other
      end

    strict |> to_string() |> String.split(":", parts: 2) |> List.first()
  end

  # Count occurrences of element `idx` of the stored {strict, broad} tuples.
  # Tolerates legacy bare-string entries (a resumed session's state) by treating
  # them as both signatures.
  defp tally(entries, idx) do
    entries
    |> Enum.map(fn
      tuple when is_tuple(tuple) -> elem(tuple, idx)
      other -> other
    end)
    |> Enum.reduce(%{}, fn sig, acc -> Map.update(acc, sig, 1, &(&1 + 1)) end)
  end

  defp collect_iteration_signatures(results, _tool_calls) do
    Enum.flat_map(results, fn {tc, {_msg, result_str}} ->
      if failure?(result_str) do
        error_prefix =
          result_str
          |> String.slice(0, 100)
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        broad = "#{tc.name}:#{error_prefix}"

        # Validation errors name a STRUCTURAL problem (wrong/missing field), not a
        # content problem. A model retrying one usually jitters the value while
        # repeating the same mistake, which would mint a fresh value digest each
        # time and slip past the strict threshold (3) down to the broad backstop
        # (6). Key those on argument SHAPE so the repeat collapses and escalates
        # at 3. Content-mismatch errors (old_string-not-found, etc.) stay
        # value-sensitive so genuinely different edits never share a signature.
        digest = if validation_error?(error_prefix), do: args_shape_digest(tc), else: args_digest(tc)
        strict = "#{tc.name}:#{digest}:#{error_prefix}"

        [%{strict: strict, broad: broad, name: tc.name, error: error_prefix}]
      else
        []
      end
    end)
  end

  @doc """
  True when `result_str` records an actual tool FAILURE.

  Contract-first: `ToolError.model_text/1` guarantees every non-fatal failure
  body starts with `"Error:"`, and every permission refusal starts with
  `"Blocked:"`. Only when neither prefix is present do we fall back to the
  legacy indicator scan — and then only over the FIRST LINE, so a successful
  write/edit whose body embeds file content or a diff is never misread as a
  failure.

  An OPERATOR decision (permission denial, cancelled/timed-out approval,
  reject-with-steer) is a model-readable answer, not a stuck tool. Counting it
  as a failure signature let three declines of the same tool hard-halt the turn
  — the exact "it won't let me finish" symptom the non-fatal tool error
  contract exists to remove.
  """
  @spec failure?(term()) :: boolean()
  def failure?(result_str) when is_binary(result_str) do
    trimmed = String.trim_leading(result_str)

    errored? =
      String.starts_with?(trimmed, "Error:") or
        String.starts_with?(trimmed, "Blocked:") or
        first_line_looks_errored?(trimmed)

    errored? and not ToolError.user_decision?(result_str)
  end

  def failure?(_), do: false

  defp first_line_looks_errored?(text) do
    first_line = text |> String.split("\n", parts: 2) |> List.first() |> to_string()
    Enum.any?(@error_indicators, &String.contains?(first_line, &1))
  end

  # Stable digest of the call's arguments. Two calls with different arguments
  # (five different `old_string`s in the same file) get different digests and
  # therefore can never share a strict signature.
  defp args_digest(tc) do
    case Map.get(tc, :arguments) do
      m when is_map(m) -> :erlang.phash2(m)
      other -> :erlang.phash2(other)
    end
  end

  # Digest of only the argument SHAPE (which fields are present), ignoring their
  # values. Used for validation-class failures so that repeated calls making the
  # same structural mistake collapse onto one strict signature even as the model
  # jitters the payload.
  defp args_shape_digest(tc) do
    case Map.get(tc, :arguments) do
      m when is_map(m) ->
        m |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> :erlang.phash2()

      other ->
        :erlang.phash2(other)
    end
  end

  # Bad-argument / schema failures describe the call's SHAPE. Kept deliberately
  # narrow so content-mismatch errors (old_string not found, file missing) do
  # NOT match and stay value-sensitive.
  @validation_error_markers [
    "requires",
    "required",
    "invalid",
    "unknown field",
    "unknown argument",
    "unexpected",
    "missing",
    "must be",
    "must provide",
    "expected",
    "not permitted",
    "is not a valid"
  ]

  defp validation_error?(error_prefix) do
    down = String.downcase(error_prefix)
    Enum.any?(@validation_error_markers, &String.contains?(down, &1))
  end

  defp tool_for(sig, iteration_signatures) do
    case Enum.find(iteration_signatures, fn e -> e.strict == sig or e.broad == sig end) do
      %{name: name} -> name
      _ -> sig |> to_string() |> String.split(":", parts: 2) |> List.first()
    end
  end

  # Scoping text shared by the graded nudge and the recovery directive. A false
  # trip must never read as "stop working on this task" — the agent that read
  # the old wording abandoned correct, landing edits and rationalised it.
  defp scoped_context(tool) do
    "The `#{tool}` call keeps FAILING with the same error and the same arguments. " <>
      "This is only about that one repeated failing call — the current task is still " <>
      "valid and must NOT be abandoned; successful work on the same file is progress, " <>
      "not a loop. Change the arguments or the method for this one call and continue."
  end

  defp handle_doom_loop({repeated_sig_key, repeat_count}, iteration_signatures, state) do
    {triggering_tool, triggering_error} =
      case Enum.find(iteration_signatures, fn e ->
             e.strict == repeated_sig_key or e.broad == repeated_sig_key
           end) do
        %{name: name, error: err} ->
          {name, err}

        nil ->
          case String.split(to_string(repeated_sig_key), ":", parts: 2) do
            [name, err] -> {name, err}
            _ -> {"unknown", to_string(repeated_sig_key)}
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
          "[DOOM LOOP RECOVERY: The #{triggering_tool} call FAILED #{repeat_count} times with the " <>
            "same error and the same arguments: \"#{triggering_error}\". " <>
            "This is about that one failing call ONLY — the task you are working on is still " <>
            "valid, and you must NOT abandon or descope it because of this message. " <>
            "Step 1: Call file_read on the target file to see its current state. " <>
            "Step 2: Based on what you see, decide if the change is still needed. " <>
            "Step 3: If yes, use COMPLETELY DIFFERENT arguments, then carry on with the task. " <>
            "Do NOT call #{triggering_tool} with the same arguments again.]"
      }

      # Map.put (not %{state | ...}): the delegate/orchestrate path builds a loop
      # state that may omit :doom_recovery_count, and the struct-update syntax
      # raises KeyError on an absent key. Mirrors the defensive style DoomLoop
      # and the sibling detectors already use.
      state =
        state
        |> Map.put(:recent_failure_signatures, [])
        |> Map.put(:messages, Map.get(state, :messages, []) ++ [recovery_directive])
        |> Map.put(:doom_recovery_count, doom_recovery_count + 1)

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
