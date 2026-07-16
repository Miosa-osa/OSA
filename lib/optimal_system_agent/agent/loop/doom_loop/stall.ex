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
  @stall_window_size 6

  # Tools that represent forward progress on the workspace (a write or edit).
  @write_edit_tools ~w(file_write file_edit file_create write_file edit_file
                       apply_patch str_replace str_replace_editor create_file
                       file_append multi_edit)

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

    stalled? =
      length(name_window) >= @stall_window_size and
        not introduced_new_tool? and not wrote_or_edited?

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
end
