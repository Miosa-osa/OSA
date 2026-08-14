defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCall do
  @moduledoc """
  Identical-call detector.

  Catches the model spamming the same tool+args even when the calls succeed
  (the model ignores the result and re-issues). The signature-based failure
  check only catches repeated FAILURES; this catches repeated USELESS SUCCESSES.

  ## Two rules, because one shape was invisible

  **Consecutive streak** (original): `repeat_threshold/0`+ *back-to-back*
  identical `{name, args_hash}` entries. Catches `dir_list` of cwd 6× in a row.

  **Windowed repeat** (added): the same `{name, args_hash}` producing the same
  *result* N times anywhere within a sliding window of M calls, **regardless of
  what is interleaved**.

  The second rule exists because the first is structurally blind to any repeat
  with something between the occurrences. A `read -> edit -> read -> edit` cycle
  never produces a streak longer than 2, so the consecutive rule cannot see it,
  and `doom_loop_halt` fired **0 times in 0 of 52 bench runs**.

  ## The change signature is the RESULT, not the file

  The obvious exemption — "a re-read is legitimate if the file's mtime or size
  changed" — is the right idea aimed at the wrong object. What actually
  distinguishes a loop from progress is **whether the call told the model
  anything it did not already have**, and that is answered directly by the
  result bytes.

  So each windowed entry carries a hash of the result. Two occurrences count as
  repeats of each other only when their results are byte-identical. A differing
  result does not merely skip an occurrence — it **partitions the window**, so
  counting restarts from that point:

    * `read -> edit -> read` — the second read returns different bytes, so the
      count restarts. `read -> edit` cycles never accumulate. This is the
      exemption the brief asks for, obtained without stat'ing anything.
    * `test -> fix -> test` — same command, different output once the fix lands.
      Never accumulates. This matters: an identical `shell_execute` re-running a
      test suite is the *legitimate* analogue of read-after-edit, and the
      stat-based exemption would not have covered it at all.
    * The same call returning the same bytes five times in twenty calls is,
      provably, five calls that carried zero information.

  This also removes the need for a hand-maintained list of "read-only tools":
  the rule is uniform, and it is the tool's own output that decides.

  ## Two exemptions for waiting, both measured

  Polling is a repeat that *should* return the same thing:

    * `@poll_tools` — `bash_output` and friends exist to be called repeatedly
      until a background job produces something. Excluded entirely.
    * **Empty results never count.** Measured on `train-fasttext`:
      `shell_execute "sleep 90"` 8× and `bash_output` 6× against a training job,
      all returning `""`. An empty result carries no information *to compare*,
      so treating two of them as "the same answer" is a category error. Without
      this exemption the replay halts two runs mid-wait — precisely the
      "fewer turns with fewer solves" trap.

  ## Measured behaviour of the windowed rule

  Replayed over **all 52 OSA bench runs** on disk (52 runs, ~2,800 tool calls),
  with the thresholds below:

    * halts: **0 runs**
    * nudges: **4 runs** (2 of them solved runs — a nudge is a system message,
      not a stop)
    * runs halted that were solved: **0**, including `path-tracing`, which was
      solved at 174 calls and never reaches a count above 1.

  It is therefore a backstop against a pathology this corpus does not contain,
  bought at a measured cost of zero. It is **not** a turn-reduction lever, and
  should not be described as one — see `docs/research/turn-count-diagnosis.md`
  and the correction recorded alongside it.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Resample

  # Tracks the last N tool invocations as `{name, args_hash}` tuples and halts
  # when `repeat_threshold/0`+ consecutive entries are identical. Independent of
  # success vs. error — protects against the model looping on a working tool
  # when it isn't using the result. The threshold is read from the shared
  # `:doom_loop_resample` settings (default 4) so detection sensitivity and the
  # resample remedy are configured together, matching grok's combined
  # `DoomLoopRecoverySettings`.
  @default_repeat_threshold 4

  # ── Windowed repeat ───────────────────────────────────────────────────
  #
  # Chosen against the measured distribution, then verified by replaying all 52
  # runs (see moduledoc). `20` spans a dense repeat phase without reaching back
  # into unrelated earlier work; `3` and `5` are the counts at which a
  # byte-identical result stops being coincidence and stops being arguable.
  @windowed_window 20
  @windowed_nudge 3
  @windowed_halt 5

  # Tools whose entire purpose is to be called repeatedly until something
  # changes. An identical result from these is correct waiting, not a loop.
  @poll_tools ~w(bash_output background_output task_status yield_time sleep wait)

  # Threshold before an identical-call loop is declared. Configurable via
  # `config :optimal_system_agent, :doom_loop_resample, threshold: N`.
  defp repeat_threshold, do: Resample.threshold()

  # Sliding window sized to always accommodate the threshold (min 8) so a raised
  # threshold can never exceed the window and silently disable detection.
  defp repeat_window, do: max(@default_repeat_threshold * 2, repeat_threshold() * 2)

  @doc "Window size, in tool calls, used by the windowed-repeat rule."
  def windowed_window, do: @windowed_window

  @doc "Occurrences within the window that trigger a graded nudge."
  def windowed_nudge_threshold, do: @windowed_nudge

  @doc "Occurrences within the window that trigger a halt."
  def windowed_halt_threshold, do: @windowed_halt

  @doc """
  Check the incoming tool calls for an identical-call loop.

  `results` is the loop's `[{tool_call, {message, result_string}}]` list. It may
  be empty (or omitted, via `check/2`), in which case only the consecutive-streak
  rule can fire — the windowed rule needs result bytes to tell a loop from
  progress, and without them it declines to guess.

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  def check(results \\ [], tool_calls, state) do
    threshold = repeat_threshold()
    window = repeat_window()

    new_keys = Enum.map(tool_calls, &call_key/1)

    history =
      (Map.get(state, :recent_call_keys, []) ++ new_keys)
      |> Enum.take(-window)

    state = Map.put(state, :recent_call_keys, history)

    # Kept separately from `:recent_call_keys`: it carries the result signature
    # and needs a longer span than the consecutive rule's window.
    windowed_history =
      (Map.get(state, :windowed_call_keys, []) ++ windowed_entries(results))
      |> Enum.take(-@windowed_window)

    state = Map.put(state, :windowed_call_keys, windowed_history)

    # Waiting is not looping, and that applies to BOTH rules.
    #
    # The consecutive rule predates the waiting exemptions and had no notion of
    # them, so polling a background job with `bash_output` four times in a row —
    # the documented way to wait for background work — halted the session. No
    # bench run happened to poll four times *consecutively*, so it never fired
    # there; it is a latent trap rather than an observed failure, and it is
    # exactly the "stop the agent early" mistake the whole change set is meant
    # to avoid. Gate both rules on the same eligibility.
    if waiting?(tool_calls, results) do
      {:ok, state}
    else
      case consecutive_streak(history) do
        {{tool, _hash}, n} when n >= threshold ->
          halt(tool, n, :identical_repeat, consecutive_message(tool, n), state)

        {{tool, _hash}, n} when n == threshold - 1 ->
          # One below the hard identical-call cap: nudge a change of approach
          # before the next repeat triggers the halt above.
          Escalation.graded(
            :approaching_identical_repeat,
            "You have called `#{tool}` with identical arguments #{n} times in a row.",
            state
          )

        _ ->
          windowed_check(windowed_history, state)
      end
    end
  end

  # Is the most recent call a wait rather than a repeat?
  #
  # Name-based pollers are recognised with or without result bytes. An empty
  # result can only be recognised when results are supplied; with none, the
  # call is treated as eligible, preserving the original behaviour for callers
  # that pass only tool calls.
  defp waiting?(tool_calls, results) do
    case List.last(tool_calls) do
      %{name: name} ->
        poll_tool?(name) or last_result_empty?(results)

      _ ->
        false
    end
  end

  defp last_result_empty?(results) when is_list(results) and results != [] do
    case List.last(results) do
      {_tc, {_msg, result}} -> String.trim(to_text(result)) == ""
      {_tc, result} -> String.trim(to_text(result)) == ""
      _ -> false
    end
  end

  defp last_result_empty?(_), do: false

  # ── Consecutive streak (original rule) ────────────────────────────────

  defp consecutive_streak(history) do
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
  end

  # ── Windowed repeat (added rule) ──────────────────────────────────────

  defp windowed_check([], state), do: {:ok, state}

  defp windowed_check(history, state) do
    case List.last(history) do
      {{tool, _hash} = key, sig, true} ->
        n = windowed_count(history, key, sig)

        cond do
          n >= @windowed_halt ->
            halt(tool, n, :windowed_identical_repeat, windowed_message(tool, n), state)

          n >= @windowed_nudge ->
            Escalation.graded(
              :approaching_windowed_repeat,
              "You have called `#{tool}` with identical arguments #{n} times within the last " <>
                "#{@windowed_window} tool calls, and every one returned byte-identical output — " <>
                "so none of them told you anything the first did not.",
              state
            )

          true ->
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  # Occurrences of `{key, sig}` in the window, scanning backwards and stopping
  # at the first entry with the same key but a DIFFERENT result.
  #
  # That stop is the exemption. When an edit (or a fix, or anything else) changes
  # what the call returns, everything before it describes a different world and
  # must not count — so `read -> edit -> read -> edit` scores 1 forever rather
  # than accumulating toward a halt.
  #
  # Ineligible entries (polling tools, empty results) are skipped without
  # counting and without partitioning: they are neither evidence of a loop nor
  # evidence of progress.
  defp windowed_count(history, key, sig) do
    history
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn
      {^key, ^sig, true}, acc -> {:cont, acc + 1}
      {^key, _other, true}, acc -> {:halt, acc}
      _, acc -> {:cont, acc}
    end)
  end

  # ── Keys and signatures ───────────────────────────────────────────────

  defp call_key(tc) do
    args =
      case Map.get(tc, :arguments) do
        m when is_map(m) -> m
        _ -> %{}
      end

    {tc.name, :erlang.phash2(args)}
  end

  # `[{tool_call, {message, result_string}}] -> [{key, result_hash, eligible?}]`.
  defp windowed_entries(results) when is_list(results) do
    Enum.flat_map(results, fn
      {tc, {_msg, result}} when is_map(tc) -> [entry(tc, result)]
      {tc, result} when is_map(tc) -> [entry(tc, result)]
      _ -> []
    end)
  end

  defp windowed_entries(_), do: []

  defp entry(tc, result) do
    text = to_text(result)
    {call_key(tc), :erlang.phash2(text), eligible?(tc.name, text)}
  end

  defp to_text(result) when is_binary(result), do: result
  defp to_text(nil), do: ""
  defp to_text(result), do: inspect(result)

  # A repeat is only evidence of a loop when the tool is not a poller and the
  # result actually says something. See the moduledoc on waiting.
  defp eligible?(name, text), do: not poll_tool?(name) and String.trim(text) != ""

  defp poll_tool?(name) do
    name = to_string(name)
    name in @poll_tools or String.contains?(String.downcase(name), "poll")
  end

  # ── Halt ──────────────────────────────────────────────────────────────

  defp halt(tool, n, reason, msg, state) do
    Logger.warning("[doom] Identical-call loop on #{tool} (#{n}x, #{reason}) — halting")

    Bus.emit(:doom_loop_halt, %{
      session_id: state.session_id,
      reason: reason,
      tool: tool,
      repeats: n
    })

    {:halt, msg, state}
  end

  defp consecutive_message(tool, n) do
    "Stopped: tool `#{tool}` was called with identical arguments #{n} times in a row " <>
      "without making progress. The result of an earlier call is already in context — " <>
      "use it, or try a different tool / different arguments."
  end

  defp windowed_message(tool, n) do
    "Stopped: tool `#{tool}` was called with identical arguments #{n} times within the last " <>
      "#{@windowed_window} tool calls, and every one returned byte-identical output — so none " <>
      "of them told you anything the first did not. Repeating it is not advancing the task. " <>
      "That output is already in context: use it. If you need something different, change the " <>
      "arguments, or change the approach entirely — if the answer you need is not in this " <>
      "output, it will not appear by asking again."
  end
end
