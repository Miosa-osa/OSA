defmodule OptimalSystemAgent.Agent.TaskQueueLeaseTest do
  @moduledoc """
  Double-execution regressions in the leased task queue.

  `complete/2` and `fail/2` used to look a task up by id ALONE — no status
  check, no `leased_by` check, no lease epoch. `do_reap_expired/1` reverts an
  expired lease to `:pending` and the next `lease/2` hands it to another agent,
  so:

    - the original slow worker's later `complete/2` overwrote the SECOND
      worker's in-flight task, and
    - its `fail/2` reverted a task another agent was actively running, causing
      a third execution.

  The reap also reset to `:pending` WITHOUT incrementing `attempts`, so
  `max_attempts` was enforced only on the explicit-fail path and a task that
  hangs its worker re-executed forever.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.TaskQueue

  setup do
    start_supervised!(TaskQueue)
    :ok
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # get_task/1 replies {:ok, task}; unwrap so assertions read cleanly.
  defp fetch(id) do
    assert {:ok, task} = TaskQueue.get_task(id)
    task
  end

  # Lease with a already-elapsed duration, then reap, so the task is back in
  # play while the "original worker" still believes it holds the lease.
  defp lease_and_expire(agent) do
    assert {:ok, task} = TaskQueue.lease(agent, 1)
    Process.sleep(10)
    TaskQueue.reap_expired_leases()
    # Flush the cast.
    _ = fetch(task.task_id)
    task
  end

  describe "stale lease holders cannot clobber the current holder" do
    test "a reaped worker's complete/3 does not overwrite the second worker's task" do
      id = uid("clobber")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{"work" => 1}, max_attempts: 5)
      first = lease_and_expire(agent)

      # A second worker picks the task up.
      assert {:ok, second} = TaskQueue.lease(agent, 60_000)
      assert second.task_id == id
      assert second.lease_epoch > first.lease_epoch

      # The original slow worker finally reports success with its STALE lease.
      TaskQueue.complete(id, %{"from" => "stale"}, lease_epoch: first.lease_epoch)

      task = fetch(id)
      assert task.status == :leased, "the second worker's in-flight task was overwritten"
      assert task.result == nil
    end

    test "a reaped worker's fail/3 does not revert a task another agent is running" do
      id = uid("revert")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{"work" => 1}, max_attempts: 5)
      first = lease_and_expire(agent)

      assert {:ok, _second} = TaskQueue.lease(agent, 60_000)

      TaskQueue.fail(id, :stale_worker_error, lease_epoch: first.lease_epoch)

      task = fetch(id)

      assert task.status == :leased,
             "a stale fail reverted the task, handing it to a THIRD executor"
    end

    test "a duplicate complete on an already-terminal task is dropped" do
      id = uid("dup")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{}, max_attempts: 5)
      assert {:ok, leased} = TaskQueue.lease(agent, 60_000)

      TaskQueue.complete(id, %{"n" => 1}, lease_epoch: leased.lease_epoch)
      assert %{status: :completed, result: %{"n" => 1}} = fetch(id)

      TaskQueue.complete(id, %{"n" => 2}, lease_epoch: leased.lease_epoch)
      assert %{status: :completed, result: %{"n" => 1}} = fetch(id)
    end

    test "a complete from an agent that does not hold the lease is rejected" do
      id = uid("wrongagent")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{}, max_attempts: 5)
      assert {:ok, _} = TaskQueue.lease(agent, 60_000)

      TaskQueue.complete(id, %{"n" => 1}, agent_id: "someone-else")
      assert %{status: :leased, result: nil} = fetch(id)
    end
  end

  describe "expired leases count against max_attempts" do
    test "a task that hangs its worker every time eventually fails instead of looping" do
      id = uid("poison")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{}, max_attempts: 2)

      lease_and_expire(agent)
      assert %{status: :pending, attempts: 1} = fetch(id)

      lease_and_expire(agent)

      task = fetch(id)
      assert task.attempts == 2
      assert task.status == :failed, "a poison task re-leased forever"
      assert task.error == :lease_expired

      # And it is no longer leasable.
      assert TaskQueue.lease(agent, 60_000) == :empty
    end
  end
end
