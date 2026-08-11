defmodule OptimalSystemAgent.Agent.BackgroundNotifierStallTest do
  @moduledoc """
  Wave 1 — the backend's stall detection had zero consumers.

  `Orchestrator`'s phase-aware watcher emits `:background_agent_stalled` on the
  parent session topic AND on the Bus, and nothing anywhere subscribed: the only
  party that can act on a wedged teammate (the parent model) never heard about
  it. This locks the notifier half of the fix.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.BackgroundNotifier
  alias OptimalSystemAgent.Agent.TaskNotifications, as: TN

  setup do
    if :ets.whereis(:osa_task_notifications) == :undefined do
      :ets.new(:osa_task_notifications, [:named_table, :public, :ordered_set])
    end

    if :ets.whereis(:osa_task_notified) == :undefined do
      :ets.new(:osa_task_notified, [:named_table, :public, :set])
    end

    parent = "bg-stall-" <> Integer.to_string(System.unique_integer([:positive]))
    TN.drain(parent)
    {:ok, parent: parent}
  end

  defp stall_event(agent_id) do
    %{
      type: :background_agent_stalled,
      session_id: "ignored",
      agent_id: agent_id,
      display_name: "explorer",
      role: "researcher",
      phase: :working,
      stalled_ms: 14 * 60 * 1000,
      tool_count: 3,
      message:
        "Background agent @explorer has made no progress for 14 minutes: it ran 3 tool(s) " <>
          "and then went quiet"
    }
  end

  test "a stall reaches the model as a queued task-notification", %{parent: parent} do
    {:ok, pid} = BackgroundNotifier.ensure_started(parent)
    agent_id = parent <> ":1"

    send(pid, {:osa_event, stall_event(agent_id)})
    # Round-trip a call through the GenServer so the cast-like send is processed.
    _ = :sys.get_state(pid)

    notifications = TN.drain(parent)

    assert [%{task_id: ^agent_id, status: :stalled, summary: summary}] = notifications,
           "stall never reached the model: #{inspect(notifications)}"

    assert summary =~ "no progress"
    assert summary =~ "14 minutes"
  end

  test "a stall does not consume the terminal exactly-once token", %{parent: parent} do
    # A stall is NOT terminal — the agent may still finish. If the stall burned
    # `mark_notified/1`, the real completion would later be silently dropped.
    {:ok, pid} = BackgroundNotifier.ensure_started(parent)
    agent_id = parent <> ":2"

    send(pid, {:osa_event, stall_event(agent_id)})
    _ = :sys.get_state(pid)
    assert [%{status: :stalled}] = TN.drain(parent)

    send(
      pid,
      {:osa_event,
       %{
         type: :background_agent_completed,
         agent_id: agent_id,
         display_name: "explorer",
         role: "researcher",
         result: "found 4 dead paths",
         duration_ms: 900_000,
         usage: %{total_tokens: 40_123, tool_uses: 12, duration_ms: 900_000}
       }}
    )

    _ = :sys.get_state(pid)

    assert [%{task_id: ^agent_id, status: :completed, summary: summary}] = TN.drain(parent),
           "the stall swallowed the completion's exactly-once token"

    assert summary =~ "found 4 dead paths"
  end
end
