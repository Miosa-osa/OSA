defmodule OptimalSystemAgent.Agent.Loop.Regulation.Homeostat do
  @moduledoc """
  The turn's homeostat (item 6) — four essential variables, each with a band
  and an automatic corrective action taken through EXISTING mechanisms:

    * **context utilization** — too high -> collapse old tool results via the
      existing microcompact pass (`Agent.Compactor.micro_compact/1`, the same
      cheap standalone pass `ReactLoop.run/1` already runs in its own warning
      band). This is a narrow, single function
      (`relieve_context/1`, private) so the context-management lane can later
      redirect it at its own, purpose-built relief function without touching
      any other part of this module.
    * **cost rate** — reframed as the exact shape from the incident this was
      built for: dollars spent THIS TURN while nothing changed on disk. Too
      high -> reported back to `Pain`, which folds it into the ONE unified
      pain score (item 2: "cost too high -> emit pain" is explicitly this
      channel, not a second one).
    * **progress rate** — edits made, a newly-tried tool, or a recognised
      check (test/build command) that ran clean, measured from the REAL
      events this iteration produced (not a self-report). Too low for
      `progress_low_streak` consecutive iterations -> a short reorientation
      note is injected once at the crossing — a lighter, EARLIER nudge than
      `DoomLoop.Stall`'s own graded escalation + checkpoint replan, which
      remains the backstop for a stall that outlives this nudge.
    * **error rate** — ratio of erroring tool calls over a rolling window.
      Too high -> reported back to `Pain`, same as cost.

  Every corrective action taken here is logged (`Logger.warning` +
  `Events.Bus.emit(:system_event, %{event: :homeostat_correction, ...})`) so
  it is visible to an operator, not just inferred from its effects.

  `regulate/4` never halts. It returns `{state, report}`; `report` carries the
  four bands so `Pain` can read the two (`:cost`, `:error`) that feed the
  unified score without recomputing them.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Loop.Regulation.Signals
  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Events.Bus

  @type band :: :ok | :high | :low
  @type report :: %{
          context: %{value: float(), band: band(), corrected?: boolean()},
          cost: %{value: float(), band: band()},
          progress: %{idle_streak: non_neg_integer(), band: band(), nudged?: boolean()},
          error: %{ratio: float(), band: band()}
        }

  @check_command_patterns ~r/\b(mix test|npm test|pnpm test|yarn test|pytest|cargo test|go test|jest|rspec|dotnet test)\b/i

  @doc """
  Regulate the four essential variables for this iteration.

  `signals` is the SAME `Signals.collect/3` result the caller already
  computed for `Pain` — passed in rather than recomputed, because collecting
  signals has a side effect (`PainChannel.take_wait_ms/1` resets the
  approval-wait accumulator) that must happen exactly once per iteration.
  """
  @spec regulate(list(), list(), map(), Signals.t()) :: {map(), report()}
  def regulate(results, tool_calls, state, signals) do
    if enabled?() do
      {state, context_report} = regulate_context(state)
      cost_report = regulate_cost(signals)
      {state, progress_report} = regulate_progress(results, tool_calls, state, signals)
      {state, error_report} = regulate_error(results, state)

      {state,
       %{
         context: context_report,
         cost: cost_report,
         progress: progress_report,
         error: error_report
       }}
    else
      {state, disabled_report()}
    end
  end

  defp disabled_report do
    %{
      context: %{value: 0.0, band: :ok, corrected?: false},
      cost: %{value: 0.0, band: :ok},
      progress: %{idle_streak: 0, band: :ok, nudged?: false},
      error: %{ratio: 0.0, band: :ok}
    }
  end

  # ── Context utilization ─────────────────────────────────────────────────

  defp regulate_context(state) do
    utilization = Telemetry.context_utilization(state)
    high_pct = cfg(:context_high_pct, 85.0)

    if utilization >= high_pct and context_relief_due?(state) do
      state = relieve_context(state, utilization)
      {state, %{value: utilization, band: :high, corrected?: true}}
    else
      band = if utilization >= high_pct, do: :high, else: :ok
      {state, %{value: utilization, band: band, corrected?: false}}
    end
  end

  defp context_relief_due?(state) do
    cooldown = cfg(:context_relief_cooldown_iterations, 3)
    last = Map.get(state, :regulation_context_relief_iteration)
    is_nil(last) or Map.get(state, :iteration, 0) - last >= cooldown
  end

  # The narrow relief function — the ONE call site the context-management
  # lane can retarget. Calls the existing standalone micro-compact pass
  # (no LLM round-trip): the same relief `ReactLoop.run/1` already applies in
  # its own pre-request warning band, applied here as a second-chance catch
  # for growth that happened AFTER that check (from this iteration's own tool
  # results, folded in since).
  defp relieve_context(state, utilization) do
    current = Map.get(state, :messages, [])
    before = length(current)
    messages = OptimalSystemAgent.Agent.Compactor.micro_compact(current)
    changed? = messages != current

    if changed? do
      Logger.warning(
        "[homeostat] context utilization #{utilization}% >= high-water mark — " <>
          "micro-compacted stale tool results (session: #{Map.get(state, :session_id)})"
      )
    end

    Bus.emit(:system_event, %{
      event: :homeostat_correction,
      session_id: Map.get(state, :session_id),
      variable: :context,
      value: utilization,
      action: :micro_compact,
      messages_before: before,
      messages_after: length(messages)
    })

    state
    |> Map.put(:messages, messages)
    |> Map.put(:regulation_context_relief_iteration, Map.get(state, :iteration, 0))
  rescue
    e ->
      Logger.debug("[homeostat] context relief failed: #{Exception.message(e)}")
      state
  end

  # ── Cost rate — dollars spent this turn with nothing to show for it ────

  defp regulate_cost(signals) do
    high_usd = cfg(:cost_no_progress_usd, 0.25)
    value = signals.cost_this_turn_usd

    band =
      if value >= high_usd and signals.no_disk_change?, do: :high, else: :ok

    %{value: value, band: band}
  end

  # ── Progress rate — edits, new tools tried, checks that ran clean ─────

  defp regulate_progress(results, tool_calls, state, signals) do
    seen = Map.get(state, :distinct_tools_seen, MapSet.new())
    prev_count = Map.get(state, :regulation_prev_distinct_tool_count, 0)
    new_tool? = MapSet.size(seen) > prev_count

    # `signals.no_disk_change?` is the SAME write-detection `Signals.collect/3`
    # already ran for this iteration — read, not re-derived.
    wrote? = not signals.no_disk_change?

    checked? = check_passed?(tool_calls, results)
    progressed? = new_tool? or wrote? or checked?

    idle_streak =
      if progressed?, do: 0, else: Map.get(state, :regulation_progress_idle_streak, 0) + 1

    low_streak = cfg(:progress_low_streak, 6)
    band = if idle_streak >= low_streak, do: :low, else: :ok
    nudge_now? = idle_streak == low_streak

    state =
      state
      |> Map.put(:regulation_prev_distinct_tool_count, MapSet.size(seen))
      |> Map.put(:regulation_progress_idle_streak, idle_streak)

    state = if nudge_now?, do: inject_reorientation(state, idle_streak), else: state

    {state, %{idle_streak: idle_streak, band: band, nudged?: nudge_now?}}
  end

  defp check_passed?(tool_calls, results) do
    Enum.any?(tool_calls, fn tc ->
      command = get_command(tc)

      is_binary(command) and Regex.match?(@check_command_patterns, command) and
        not tool_errored?(tc, results)
    end)
  end

  defp get_command(%{name: "shell_execute", arguments: args}) when is_map(args),
    do: Map.get(args, "command") || Map.get(args, :command)

  defp get_command(_), do: nil

  defp tool_errored?(tc, results) do
    Enum.any?(results, fn
      {rtc, {_msg, result_str}} when is_map(rtc) and is_binary(result_str) ->
        same_call?(rtc, tc) and String.starts_with?(String.trim_leading(result_str), "Exit")

      _ ->
        false
    end)
  end

  defp same_call?(a, b) when is_map(a) and is_map(b) do
    aid = Map.get(a, :id)
    bid = Map.get(b, :id)

    if not is_nil(aid) and not is_nil(bid) do
      aid == bid
    else
      Map.get(a, :name) == Map.get(b, :name) and Map.get(a, :arguments) == Map.get(b, :arguments)
    end
  end

  defp same_call?(_a, _b), do: false

  defp inject_reorientation(state, idle_streak) do
    Logger.info(
      "[homeostat] progress idle for #{idle_streak} iterations — injecting a reorientation " <>
        "note (session: #{Map.get(state, :session_id)})"
    )

    Bus.emit(:system_event, %{
      event: :homeostat_correction,
      session_id: Map.get(state, :session_id),
      variable: :progress,
      action: :reorientation_note,
      idle_streak: idle_streak
    })

    note = %{
      role: "system",
      content:
        "[System: #{idle_streak} tool calls with no measured progress — no file changed, no " <>
          "new tool tried, no check ran clean. Before continuing, name concretely what the next " <>
          "call is expected to show, and why the last few did not show it.]"
    }

    Map.put(state, :messages, Map.get(state, :messages, []) ++ [note])
  end

  # ── Error rate ──────────────────────────────────────────────────────────

  defp regulate_error(results, state) do
    window_size = cfg(:error_rate_window, 10)
    this_iteration_flags = Enum.map(results, &result_error?/1)

    window =
      (Map.get(state, :regulation_error_window, []) ++ this_iteration_flags)
      |> Enum.take(-window_size)

    state = Map.put(state, :regulation_error_window, window)

    ratio =
      case window do
        [] -> 0.0
        _ -> Enum.count(window, & &1) / length(window)
      end

    high = cfg(:error_rate_high, 0.5)
    band = if length(window) >= 3 and ratio >= high, do: :high, else: :ok

    {state, %{ratio: ratio, band: band}}
  end

  defp result_error?({_tc, {_msg, result_str}}) when is_binary(result_str) do
    trimmed = String.trim_leading(result_str)

    String.starts_with?(trimmed, "Error:") or String.starts_with?(trimmed, "Blocked:") or
      String.starts_with?(trimmed, "Exit")
  end

  defp result_error?(_), do: false

  defp enabled?, do: Keyword.get(config(), :enabled, true)
  defp cfg(key, default), do: Keyword.get(config(), key, default)
  defp config, do: Application.get_env(:optimal_system_agent, :regulation_homeostat, [])
end
