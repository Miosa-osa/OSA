defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.Stall do
  @moduledoc """
  Stall detector — catches *non-progress* (as opposed to *repetition*).

  Distinct from the identical-call and failure-signature checks: those catch
  *repetition*, this catches *non-progress*. If the last 6 tool calls
  introduced no newly-distinct tool AND performed no file write/edit, the agent
  is spinning. It emits the graded escalation via `Escalation` and only
  hard-halts once the graded steps are exhausted.

  The sliding windows it needs (`:distinct_tools_seen`, `:recent_tool_names`,
  `:distinct_count_log`) are threaded explicitly on `state`.
  """
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Loop.DoomLoop.Escalation

  # Stall detection: if the last N tool calls introduce no newly-distinct tool
  # and perform no file write/edit, the agent is spinning without progress.
  # Widened from 6 → 12 so a legitimate long investigation phase (many reads
  # in a row) isn't mistaken for a stall.
  @stall_window_size 12

  # Tools that represent forward progress on the workspace (a write or edit).
  @write_edit_tools ~w(file_write file_edit file_create write_file edit_file
                       apply_patch str_replace str_replace_editor create_file
                       file_append multi_edit)

  # Investigation tools — reading/searching/running-a-command IS forward
  # progress during a long autonomous work phase (exactly what hours-long work
  # does). A window containing any of these is not a stall, so a legitimate
  # read/analysis/diagnose phase is never wrongly halted.
  #
  # Command execution (`shell_execute`, `bash`, `pty_*`, `task_output`) is
  # included: an iterative debugging phase — run the linter, read the errors,
  # run it again — is dominated by shell calls that each return NEW output, and
  # without these a real fix-the-eslint-errors loop tripped the graded nudge
  # ("no forward progress for 12 tool calls") mid-work. A genuinely stuck shell
  # loop is still caught: IdenticalCall halts exact repeats and FailureSignature
  # halts a command that keeps failing the same way — Stall is only for
  # non-progress, and a command returning fresh output is progress.
  @progress_tools ~w(file_read read_file file_grep grep dir_list list_dir
                     file_glob glob file_search web_fetch web_search
                     semantic_search code_symbols
                     shell_execute bash run_command sh
                     pty_send pty_read pty_start task_output task_wait)

  # --- Stall detection ---
  #
  # Distinct from the identical-call and failure-signature checks: those catch
  # *repetition*, this catches *non-progress*. If the last `@stall_window_size`
  # tool calls introduced no newly-distinct tool AND performed no file
  # write/edit, the agent is spinning. We emit the graded escalation and only
  # hard-halt once the graded steps are exhausted.
  @doc """
  Check the incoming tool calls for a stall (non-progress).

  `results` is the loop's `[{tool_call, {message, result_string}}]` list for the
  current batch, used to make write/edit detection RESULT-AWARE (P1-8): a
  reask, an error, or an identical/no-files-modified result executed no write
  and must not count as progress. It is optional and defaults to `[]`; when it
  is empty the check falls back to name-only write detection (unchanged
  behaviour).

  NOTE(turn-hardening): the orchestrator (`DoomLoop.check/3` in `doom_loop.ex`,
  not in this workstream) still calls `Stall.check(tool_calls, state)` WITHOUT
  results, so in production the result-aware path below is dormant and a failing
  edit still counts as a write. Threading `results` into that one call site (it
  already holds them for `IdenticalCall`/`FailureSignature`) activates the fix.

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  def check(tool_calls, state, results \\ []) do
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

    # Per-call "was this a REAL, successful write/edit?" flags, windowed
    # alongside `name_window`. Result-aware when `results` are supplied; falls
    # back to name-only (any write/edit-named call counts) when they are not,
    # so callers that pass no results behave exactly as before (P1-8).
    write_status_this_batch = Enum.map(tool_calls, &counts_as_write?(&1, results))

    write_status_window =
      (Map.get(state, :recent_write_status, []) ++ write_status_this_batch)
      |> Enum.take(-@stall_window_size)

    state =
      state
      |> Map.put(:distinct_tools_seen, distinct_after)
      |> Map.put(:recent_tool_names, name_window)
      |> Map.put(:distinct_count_log, count_log)
      |> Map.put(:recent_write_status, write_status_window)

    introduced_new_tool? =
      length(count_log) < @stall_window_size + 1 or
        List.last(count_log) > List.first(count_log)

    # A window counts as "wrote or edited" when any covered call really wrote,
    # OR when an OLDER window slot (present in `name_window` but not covered by
    # the status window - a directly-seeded `recent_tool_names` in a test, or a
    # pre-fix resumed session) is a write/edit tool. The uncovered slots are the
    # oldest, since both windows are right-aligned.
    uncovered = max(length(name_window) - length(write_status_window), 0)

    wrote_or_edited? =
      Enum.any?(write_status_window) or
        (name_window |> Enum.take(uncovered) |> Enum.any?(&write_or_edit_tool?/1))

    investigated? = Enum.any?(name_window, &progress_tool?/1)

    stalled? =
      length(name_window) >= @stall_window_size and
        not introduced_new_tool? and not wrote_or_edited? and not investigated?

    if stalled? do
      case Escalation.escalate(
             :stall,
             "The last #{@stall_window_size} tool calls made no progress: " <>
               "no new file was written or edited and no new tool was tried.",
             state
           ) do
        {:escalated, state} ->
          {:ok, state}

        {:exhausted, state} ->
          if hard_halt?(state) do
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
          else
            # Autonomous mode (stall_hard_halt: false, or :overdrive/:auto): never
            # kill a long unattended run on a stall — the operator-set
            # max_budget_usd + absolute call cap are the real stops, and
            # `path-tracing` was *solved* at 175 turns, so stopping early is the
            # expensive mistake here, not continuing.
            #
            # But this branch used to be a bare log-and-continue, and that is
            # worse than having no detector: measured, it logged "Stall detected"
            # **247 times in one run and 81 in another with zero effect**, because
            # `Escalation` caps at 3 nudges and everything after that fell through
            # to this line. A detector that fires 247 times and changes nothing is
            # a false assurance — the logs say the system noticed while the system
            # did not act.
            #
            # So an exhausted stall now *checkpoints*: it records the state and
            # surfaces it, and periodically forces a written re-plan. It still
            # never halts.
            checkpoint(state)
          end
      end
    else
      {:ok, state}
    end
  end

  # ── Exhausted-stall checkpoint ────────────────────────────────────────

  # How many exhausted-stall detections pass between forced re-plans. The first
  # one always checkpoints; after that, every `@checkpoint_interval`-th.
  #
  # Sized from the measured detection volume: 247 detections in the worst run.
  # At 1-in-25 that is ~10 re-plans across a 305-turn run — frequent enough that
  # a genuinely stuck agent is asked to reconsider roughly every 30 turns, rare
  # enough that it cannot itself become the loop. Injecting on all 247 would
  # add 247 system messages to a transcript whose growth is already the dominant
  # cost term.
  @checkpoint_interval 25

  # Record the stall and surface it; periodically force a written re-plan.
  # Always returns `{:ok, state}` — this path must never halt.
  defp checkpoint(state) do
    n = Map.get(state, :stall_checkpoint_count, 0) + 1
    state = Map.put(state, :stall_checkpoint_count, n)

    # Surface it as a measured event on every detection, even when no directive
    # is injected. The count is the point: "the stall detector fired 247 times"
    # is only knowable if each firing is recorded somewhere structured.
    Bus.emit(:system_event, %{
      event: :stall_checkpoint,
      session_id: state.session_id,
      detection: n,
      window: @stall_window_size,
      recent_tools: state |> Map.get(:recent_tool_names, []) |> Enum.uniq(),
      total_tool_calls: Map.get(state, :total_tool_calls, 0),
      replan_injected: replan?(n)
    })

    if replan?(n) do
      Logger.warning(
        "[doom] Stall checkpoint ##{n} — graded escalation exhausted, forcing a written re-plan " <>
          "(session: #{state.session_id})"
      )

      {:ok, inject_replan(state, n)}
    else
      Logger.info(
        "[doom] Stall checkpoint ##{n} — recorded, next re-plan at " <>
          "##{next_replan_at(n)} (session: #{state.session_id})"
      )

      {:ok, state}
    end
  end

  defp replan?(1), do: true
  defp replan?(n), do: rem(n, @checkpoint_interval) == 0

  defp next_replan_at(n), do: (div(n, @checkpoint_interval) + 1) * @checkpoint_interval

  # The directive asks for *writing*, not stopping.
  #
  # Deliberately not "you are stuck, give up": the diagnosis is explicit that a
  # hard halt here is the "give up earlier" trap, and that fewer turns with
  # fewer solves is not a win. It asks the agent to externalise the plan, which
  # is the behaviour that distinguished the harnesses that solved these tasks —
  # they built durable artefacts and iterated against them, rather than probing
  # inline and self-certifying.
  defp inject_replan(state, n) do
    tried =
      state
      |> Map.get(:recent_tool_names, [])
      |> Enum.uniq()
      |> Enum.join(", ")

    directive = %{
      role: "system",
      content:
        "[STALL CHECKPOINT #{n} — no forward progress for #{@stall_window_size}+ tool calls, " <>
          "and the graded nudges are exhausted] " <>
          "Stop acting and write out, explicitly, in your next message: " <>
          "(1) the goal, restated in one sentence; " <>
          "(2) what you have already tried" <>
          if(tried == "", do: "", else: " (recent tools: #{tried})") <>
          " and what each attempt actually showed; " <>
          "(3) the specific thing that is blocking you, and the assumption behind it that " <>
          "might be wrong; " <>
          "(4) one concrete next step that is DIFFERENT in kind from what you have been doing. " <>
          "Then do only that step. If you are repeatedly inspecting the same thing, the " <>
          "information you need is not there — change where you are looking. If you are " <>
          "repeatedly running the same check, write the check to a file so you can see it " <>
          "fail and then see it pass. You are not being stopped; keep working after you have " <>
          "written this."
    }

    Map.put(state, :messages, Map.get(state, :messages, []) ++ [directive])
  end

  # An autonomous run (:overdrive mode / :auto tier) gets a hard stop too, but a
  # far more lenient one than an attended run: it keeps checkpointing and
  # nudging until roughly 2x the attended window of exhausted-stall detections
  # has accumulated, then halts so an unattended rabbit hole cannot spin forever
  # (P2-20). Attended runs still halt as soon as the graded escalation is
  # exhausted.
  @autonomous_hard_halt_after @stall_window_size * 2

  # Whether an exhausted stall should hard-halt the run.
  #
  # Gated by `stall_hard_halt` (shipped `false`, so by default nothing hard-halts
  # and the checkpoint path runs everywhere - attended behaviour unchanged). When
  # hard-halting is enabled, an attended run halts immediately; an autonomous run
  # (:overdrive / :auto) is given the lenient 2x-window budget above before it
  # finally halts (P2-20).
  defp hard_halt?(state) do
    cond do
      not Application.get_env(:optimal_system_agent, :stall_hard_halt, true) ->
        false

      autonomous?(state) ->
        Map.get(state, :stall_checkpoint_count, 0) >= @autonomous_hard_halt_after

      true ->
        true
    end
  end

  defp autonomous?(state) do
    Map.get(state, :permission_mode) == :overdrive or
      Map.get(state, :permission_tier) == :auto
  end

  defp progress_tool?(name) do
    downcased = name |> to_string() |> String.downcase()

    name in @progress_tools or
      String.contains?(downcased, "read") or
      String.contains?(downcased, "grep") or
      String.contains?(downcased, "search") or
      String.contains?(downcased, "list") or
      String.contains?(downcased, "glob") or
      String.contains?(downcased, "fetch")
  end

  defp write_or_edit_tool?(name) do
    downcased = name |> to_string() |> String.downcase()

    name in @write_edit_tools or
      String.contains?(downcased, "write") or
      String.contains?(downcased, "edit") or
      String.contains?(downcased, "patch")
  end

  # A call counts as forward progress only when it is a write/edit tool AND it
  # actually wrote something. A reask/error/no-op write executed nothing (P1-8).
  defp counts_as_write?(tc, results) do
    write_or_edit_tool?(tc.name) and write_succeeded?(tc, results)
  end

  # True when there is no evidence this write/edit failed. With a matching
  # binary result we require a genuine successful write; without one (no results
  # supplied, or no match) we fall back to name-only (assume it wrote), so
  # callers that pass no results keep their prior behaviour.
  defp write_succeeded?(tc, results) do
    case find_result(tc, results) do
      {:ok, result_str} when is_binary(result_str) -> write_result_success?(result_str)
      _ -> true
    end
  end

  defp find_result(tc, results) when is_list(results) do
    Enum.find_value(results, :error, fn
      {rtc, {_msg, result_str}} when is_map(rtc) ->
        if same_call?(rtc, tc), do: {:ok, result_str}, else: nil

      {rtc, result_str} when is_map(rtc) ->
        if same_call?(rtc, tc), do: {:ok, result_str}, else: nil

      _ ->
        nil
    end)
  end

  defp find_result(_tc, _results), do: :error

  # Match the result's tool_call to the one being scored: by id when both carry
  # one, else by name + arguments.
  defp same_call?(a, b) when is_map(a) and is_map(b) do
    aid = Map.get(a, :id)
    bid = Map.get(b, :id)

    if not is_nil(aid) and not is_nil(bid) do
      aid == bid
    else
      Map.get(a, :name) == Map.get(b, :name) and
        Map.get(a, :arguments) == Map.get(b, :arguments)
    end
  end

  defp same_call?(_a, _b), do: false

  # A write/edit result is a real write unless it errored/was blocked (a reask
  # is `Error:`-prefixed too) or was an identical/no-files-modified no-op.
  defp write_result_success?(result_str) do
    trimmed = String.trim_leading(result_str)

    not (String.starts_with?(trimmed, "Error:") or
           String.starts_with?(trimmed, "Blocked:") or
           String.contains?(result_str, "No change needed") or
           String.contains?(result_str, "No changes needed"))
  end
end
