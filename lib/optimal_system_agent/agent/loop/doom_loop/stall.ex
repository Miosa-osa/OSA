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

  # Investigation tools — reading/searching IS forward progress during a long
  # autonomous research phase (exactly what hours-long work does). A window
  # containing any of these is not a stall, so a legitimate read/analysis phase
  # is never wrongly halted.
  @progress_tools ~w(file_read read_file file_grep grep dir_list list_dir
                     file_glob glob file_search web_fetch web_search
                     semantic_search code_symbols)

  # --- Stall detection ---
  #
  # Distinct from the identical-call and failure-signature checks: those catch
  # *repetition*, this catches *non-progress*. If the last `@stall_window_size`
  # tool calls introduced no newly-distinct tool AND performed no file
  # write/edit, the agent is spinning. We emit the graded escalation and only
  # hard-halt once the graded steps are exhausted.
  @doc """
  Check the incoming tool calls for a stall (non-progress).

  Returns `{:ok, state}` to continue or `{:halt, message, state}` to stop.
  """
  def check(tool_calls, state) do
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

  # Whether an exhausted stall should hard-halt the run. Autonomous runs
  # (config `stall_hard_halt: false`, or an :overdrive permission mode / :auto
  # tier) escalate-only: keep nudging, never kill.
  defp hard_halt?(state) do
    Application.get_env(:optimal_system_agent, :stall_hard_halt, true) and
      Map.get(state, :permission_mode) != :overdrive and
      Map.get(state, :permission_tier) != :auto
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
end
