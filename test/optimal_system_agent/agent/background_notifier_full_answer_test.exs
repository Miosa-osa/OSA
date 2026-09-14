defmodule OptimalSystemAgent.Agent.BackgroundNotifierFullAnswerTest do
  @moduledoc """
  Regression test — a completed background subagent's FULL final-answer text
  must reach the parent, not the truncated wire preview.

  `Orchestrator.run_background/2` slices the child's response to a few hundred
  chars before broadcasting `:background_agent_completed` (that copy is sized
  for the CLI's inline completion line). `BackgroundNotifier.inject/3` used to
  build the parent-facing `<task-notification>` summary straight from that
  slice, so anything past the first ~500 characters of a real report was lost
  before the parent ever saw it — the delegate contract elsewhere allows up to
  10,000 characters for exactly this reason (`ResultSummarizer`).

  Fixed by preferring the durable `RunStore` row for the SAME completion (written
  with the child's full response before the wire slice ever happens) and
  running it through the identical `ResultSummarizer` the foreground `delegate`
  path already uses, falling back to the event's own preview only when no row
  exists.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.BackgroundNotifier
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.TaskNotifications, as: TN

  setup do
    if :ets.whereis(:osa_task_notifications) == :undefined do
      :ets.new(:osa_task_notifications, [:named_table, :public, :ordered_set])
    end

    if :ets.whereis(:osa_task_notified) == :undefined do
      :ets.new(:osa_task_notified, [:named_table, :public, :set])
    end

    tmp =
      Path.join(
        System.tmp_dir!(),
        "osa_bgnotif_full_answer_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)

      File.rm_rf(tmp)
    end)

    parent = "bg-full-" <> Integer.to_string(System.unique_integer([:positive]))
    TN.drain(parent)
    {:ok, parent: parent}
  end

  defp completed_event(agent_id, preview) do
    %{
      type: :background_agent_completed,
      session_id: "ignored",
      agent_id: agent_id,
      display_name: "explorer",
      role: "researcher",
      # The real wire payload: `Orchestrator.run_background/2` slices to 500
      # chars before this event is ever broadcast.
      result: preview,
      duration_ms: 1234
    }
  end

  test "the full report reaches the parent even though the event carries only a slice",
       %{parent: parent} do
    agent_id = parent <> ":1"

    # A report long enough that a 500-char wire slice would sever real content,
    # but short enough to stay under ResultSummarizer's 10k cap (no truncation
    # marker expected).
    tail = "FINDING: the real conclusion lives past character 500 — do not lose me."
    long_report = String.duplicate("filler ", 100) <> tail
    assert String.length(long_report) > 500

    RunStore.start_run(%{
      agent_id: agent_id,
      parent_session_id: parent,
      role: "researcher",
      task: "investigate"
    })

    RunStore.complete(agent_id, %{
      agent_id: agent_id,
      status: :completed,
      summary: long_report,
      duration_ms: 1234
    })

    {:ok, pid} = BackgroundNotifier.ensure_started(parent)
    preview = String.slice(long_report, 0, 500)
    send(pid, {:osa_event, completed_event(agent_id, preview)})
    _ = :sys.get_state(pid)

    assert [%{task_id: ^agent_id, status: :completed, summary: summary}] = TN.drain(parent)

    assert summary =~ tail,
           "parent-facing notification lost content past the wire preview's 500-char slice"

    refute summary =~ "truncated at",
           "a report under the 10k cap should not carry a truncation marker"
  end

  test "falls back to the event's own preview when no RunStore row exists",
       %{parent: parent} do
    agent_id = parent <> ":2"

    {:ok, pid} = BackgroundNotifier.ensure_started(parent)
    send(pid, {:osa_event, completed_event(agent_id, "found 4 dead paths")})
    _ = :sys.get_state(pid)

    assert [%{task_id: ^agent_id, status: :completed, summary: summary}] = TN.drain(parent)
    assert summary =~ "found 4 dead paths"
  end
end
