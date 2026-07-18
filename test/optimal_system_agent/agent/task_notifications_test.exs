defmodule OptimalSystemAgent.Agent.TaskNotificationsTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.TaskNotifications, as: TN

  setup do
    # Tables are app-owned in production; create them here when the app
    # isn't started (they die with the test process, which is fine).
    if :ets.whereis(:osa_task_notifications) == :undefined do
      :ets.new(:osa_task_notifications, [:named_table, :public, :ordered_set])
    end

    if :ets.whereis(:osa_task_notified) == :undefined do
      :ets.new(:osa_task_notified, [:named_table, :public, :set])
    end

    {:ok, sid: "tn-test-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  test "queue/drain is FIFO and destructive", %{sid: sid} do
    :ok = TN.queue(sid, %{task_id: "a", status: :done, summary: "first"})
    :ok = TN.queue(sid, %{task_id: "b", status: :failed, summary: "second"})

    assert TN.pending?(sid)
    assert [%{task_id: "a"}, %{task_id: "b"}] = TN.drain(sid)
    assert TN.drain(sid) == []
    refute TN.pending?(sid)
  end

  test "drain does not cross sessions", %{sid: sid} do
    :ok = TN.queue(sid, %{task_id: "mine"})
    :ok = TN.queue(sid <> "-other", %{task_id: "theirs"})

    assert [%{task_id: "mine"}] = TN.drain(sid)
    assert [%{task_id: "theirs"}] = TN.drain(sid <> "-other")
  end

  test "mark_notified is check-and-set: true exactly once" do
    id = "task-" <> Integer.to_string(System.unique_integer([:positive]))
    assert TN.mark_notified(id)
    refute TN.mark_notified(id)
  end

  test "to_messages renders task-notification XML system messages" do
    [msg] =
      TN.to_messages([
        %{task_id: "bg_1", status: :done, output_file: "/tmp/osa/s/tasks/bg_1.out", summary: "ok"}
      ])

    assert msg.role == "system"
    assert msg.content =~ "<task-notification>"
    assert msg.content =~ "<task-id>bg_1</task-id>"
    assert msg.content =~ "<status>done</status>"
    assert msg.content =~ "<output-file>/tmp/osa/s/tasks/bg_1.out</output-file>"
    assert msg.content =~ "Do not poll"
  end

  test "to_xml tolerates non-string values (usage maps, atoms)" do
    xml = TN.to_xml(%{task_id: "t", status: :completed, usage: %{tokens: 12}})
    assert xml =~ "<status>completed</status>"
    assert xml =~ "<usage>"
  end
end
