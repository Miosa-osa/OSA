defmodule OptimalSystemAgent.Agent.Loop.SendNowTest do
  @moduledoc """
  Send-now (item 1): the user's queued messages interrupt the running turn
  instead of waiting for the current tool batch to finish, and still-running
  tools move to the background rather than being cancelled.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.SendNow
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.TaskNotifications

  setup do
    sid = "send-now-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      SendNow.clear(sid)
      Steer.drain(sid)
      TaskNotifications.drain(sid)
    end)

    {:ok, sid: sid}
  end

  describe "request/yield lifecycle" do
    test "request queues each text as a steer and raises the yield flag", %{sid: sid} do
      captured = self()

      :ok =
        SendNow.request(sid, ["do X", "then Y"], fn s, t ->
          send(captured, {:steered, s, t})
          Steer.queue(s, t)
        end)

      assert_received {:steered, ^sid, "do X"}
      assert_received {:steered, ^sid, "then Y"}
      assert Steer.count(sid) == 2
      assert SendNow.flagged?(sid)
      assert SendNow.yield?(sid)
    end

    test "yield? is false with no request", %{sid: sid} do
      refute SendNow.yield?(sid)
    end

    test "a raised flag with no queued steer is stale and self-clears", %{sid: sid} do
      :ok = SendNow.request(sid, ["msg"], fn _s, _t -> :ok end)
      # The flag is up, but nothing was actually queued (steer_fun no-op), so
      # the yield is stale — it must not interrupt an unrelated tool batch.
      assert SendNow.flagged?(sid)
      refute SendNow.yield?(sid)
      refute SendNow.flagged?(sid)
    end

    test "clearing the flag stops yielding even while a steer is queued", %{sid: sid} do
      :ok = SendNow.request(sid, ["msg"])
      assert SendNow.yield?(sid)
      SendNow.clear(sid)
      refute SendNow.yield?(sid)
      # The steer itself is untouched — it is still delivered at the boundary.
      assert Steer.count(sid) == 1
    end

    test "empty request neither queues nor raises the flag", %{sid: sid} do
      :ok = SendNow.request(sid, ["", "   "])
      refute SendNow.flagged?(sid)
      assert Steer.count(sid) == 0
    end
  end

  describe "task/loop exactly-once hand-off" do
    setup do
      table_owner = :ets.whereis(:osa_send_now)

      if table_owner == :undefined do
        :ets.new(:osa_send_now, [:named_table, :public, :set])
      end

      :ok
    end

    test "task_finished returns the result when the loop has not adopted the call", %{sid: sid} do
      tc = %{id: "t1", name: "shell_execute"}
      result = {%{role: "tool", tool_call_id: "t1", content: "ok"}, "ok"}
      assert SendNow.task_finished(sid, tc, result) == result
    end

    test "adopt returns a 'moved to background' result and later task_finished delivers a notification",
         %{sid: sid} do
      tc = %{id: "t2", name: "shell_execute"}

      # A task that is still running when the loop adopts it.
      task =
        Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
          receive do
            :go -> :done
          after
            2_000 -> :timeout
          end
        end)

      {msg, str} = SendNow.adopt(sid, tc, task)
      assert msg.role == "tool"
      assert str =~ SendNow.backgrounded_marker()

      # Now the task finishes: because the loop claimed :adopted, the result is
      # delivered as a task-notification instead of being returned to the turn.
      send(task.pid, :go)
      result = {%{role: "tool", tool_call_id: "t2", content: "late result"}, "late result"}
      _ = SendNow.task_finished(sid, tc, result)

      # The notification is queued for the session.
      assert TaskNotifications.count(sid) >= 1
    end
  end
end
