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
            # Autonomous mode (stall_hard_halt: false, or :overdrive/:auto): keep
            # the graded nudges but never kill a long unattended run on a stall —
            # the operator-set max_budget_usd + absolute call cap are the real stops.
            Logger.warning("[doom] Stall detected — escalate-only (autonomous mode), continuing")
            {:ok, state}
          end
      end
    else
      {:ok, state}
    end
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
