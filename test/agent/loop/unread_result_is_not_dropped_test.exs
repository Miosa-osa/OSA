defmodule OptimalSystemAgent.Agent.Loop.UnreadResultIsNotDroppedTest do
  @moduledoc """
  A background result that came back must not be left sitting unread.

  ## The window

  `TaskNotifications` is drained at exactly two sites:

    * a busy turn's step boundary — `ReactLoop.inject_pending_task_notifications/1`
      (agent/loop/react_loop.ex:292), and
    * the idle poke — `handle_cast(:poke, %{status: :idle})` (agent/loop.ex:1812).

  A turn has a LAST step boundary. Everything after it — the finalize block in
  `run_and_reply/1`, and the whole plan-mode return path, which never enters
  `run_and_reply` at all — runs with `status` still non-`:idle`, so a `:poke`
  landing there was handled by the catch-all `handle_cast(:poke, state)` at
  agent/loop.ex:1836 and dropped on the floor. Nothing re-poked.

  `TaskNotifications.pending?/1` was the obvious guard against exactly this and
  had **zero production callers** — no turn boundary ever asked whether a result
  was sitting unread. `b7823369` narrowed the window by holding a turn open
  while a delegated child is alive, and said in its own commit body that it did
  not close it.

  ## Why this closes it rather than narrowing it

  The poke is ADVISORY; the queue is the FACT. `settle/1` asks the queue at
  every point the loop finishes a turn, so it does not matter whether the poke
  was dropped by the catch-all, raced the status flip, or was never sent at all
  by some future caller that queues and forgets. All three converge on "is
  anything unread for this session", answered against the ETS table itself.

  It also cannot spin: `drain/1` is destructive, so the synthetic turn the
  re-poke starts empties the queue, and that turn's own `settle/1` finds it
  clear and stops.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.TaskNotifications

  # Records the pokes it is asked to send, in place of the real `Agent.Loop`.
  # Injected through the same config-key convention `:background_manager` and
  # `:subagent_roster` already use.
  defmodule RecordingPoker do
    def poke(session_id) do
      send(Application.get_env(:optimal_system_agent, :test_poke_sink), {:poked, session_id})
      :ok
    end
  end

  defmodule RaisingPoker do
    def poke(_session_id), do: raise("the loop is gone")
  end

  setup do
    sid = "unread-#{System.unique_integer([:positive])}"
    Application.put_env(:optimal_system_agent, :notification_poker, RecordingPoker)
    Application.put_env(:optimal_system_agent, :test_poke_sink, self())

    on_exit(fn ->
      TaskNotifications.drain(sid)
      Application.delete_env(:optimal_system_agent, :notification_poker)
      Application.delete_env(:optimal_system_agent, :test_poke_sink)
    end)

    {:ok, sid: sid}
  end

  defp queue_a_result(sid) do
    TaskNotifications.queue(sid, %{
      task_id: "child-#{System.unique_integer([:positive])}",
      status: "completed",
      result: "the explorer finished the backend session model map"
    })
  end

  describe "settle/1" do
    test "re-pokes a session that has an unread result", %{sid: sid} do
      queue_a_result(sid)

      assert TaskNotifications.settle(sid) == :unread
      assert_receive {:poked, ^sid}, 500
    end

    test "says nothing when the queue is clear", %{sid: sid} do
      assert TaskNotifications.settle(sid) == :clear
      refute_receive {:poked, ^sid}, 100
    end

    test "does not consume the result — the drain still gets it", %{sid: sid} do
      queue_a_result(sid)

      assert TaskNotifications.settle(sid) == :unread
      assert_receive {:poked, ^sid}, 500

      # `settle/1` reports; it does not read. If it consumed the notification,
      # the synthetic turn its own poke starts would find an empty queue and no
      # one would ever see the result — the same loss by a different route.
      assert [_one] = TaskNotifications.drain(sid)
    end

    test "is per-session — one session's unread result does not poke another", %{sid: sid} do
      other = "#{sid}-other"
      queue_a_result(sid)

      assert TaskNotifications.settle(other) == :clear
      refute_receive {:poked, ^other}, 100
    end

    test "a dead loop is not an exception in the finalize path", %{sid: sid} do
      # `settle/1` is called from the tail of every turn. A poke that cannot be
      # delivered (loop shutting down, name deregistered) must not take the turn
      # down with it — the result stays queued for the next incarnation.
      Application.put_env(:optimal_system_agent, :notification_poker, RaisingPoker)
      queue_a_result(sid)

      assert TaskNotifications.settle(sid) == :clear
      assert [_still_queued] = TaskNotifications.drain(sid)
    end

    test "tolerates a nil session id" do
      assert TaskNotifications.settle(nil) == :clear
    end
  end

  describe "the finalize path actually calls it" do
    # The behavioural tests above pass against a `settle/1` that nothing calls —
    # which is precisely the state `pending?/1` was in. This pins the caller.
    test "run_and_reply and the plan-mode return both settle before going idle" do
      loop = File.read!("lib/optimal_system_agent/agent/loop.ex")

      assert String.contains?(loop, "TaskNotifications.settle("),
             "the loop finishes turns without ever asking whether a result is unread"

      # Both turn-completion paths, not just the common one: plan mode returns
      # at loop.ex:2117 without ever entering run_and_reply.
      calls = length(String.split(loop, "TaskNotifications.settle(")) - 1

      assert calls >= 2,
             "only #{calls} settle site(s) — a turn-completion path still goes idle unchecked"
    end
  end
end
