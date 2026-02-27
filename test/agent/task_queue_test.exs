defmodule OptimalSystemAgent.Agent.TaskQueueTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.TaskQueue

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_queue do
    name = :"task_queue_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(TaskQueue, [], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {pid, name}
  end

  defp enqueue(name, task_id, agent_id, payload, opts \\ []) do
    GenServer.cast(name, {:enqueue, task_id, agent_id, payload, opts})
    Process.sleep(10)
  end

  defp lease(name, agent_id, lease_ms \\ 300_000) do
    GenServer.call(name, {:lease, agent_id, lease_ms})
  end

  defp complete(name, task_id, result) do
    GenServer.cast(name, {:complete, task_id, result})
    Process.sleep(10)
  end

  defp fail(name, task_id, error) do
    GenServer.cast(name, {:fail, task_id, error})
    Process.sleep(10)
  end

  defp reap_expired(name) do
    GenServer.cast(name, :reap_expired)
    Process.sleep(10)
  end

  defp get_task(name, task_id) do
    GenServer.call(name, {:get_task, task_id})
  end

  defp list_tasks(name, opts \\ []) do
    GenServer.call(name, {:list_tasks, opts})
  end

  # ---------------------------------------------------------------------------
  # enqueue
  # ---------------------------------------------------------------------------

  describe "enqueue/4" do
    test "creates pending task" do
      {_pid, name} = start_queue()

      enqueue(name, "task_001", "agent_backend", %{action: "build"})

      assert {:ok, task} = get_task(name, "task_001")
      assert task.status == :pending
      assert task.agent_id == "agent_backend"
      assert task.payload == %{action: "build"}
      assert task.attempts == 0
      assert task.max_attempts == 3
      assert %DateTime{} = task.created_at
    end
  end

  # ---------------------------------------------------------------------------
  # lease
  # ---------------------------------------------------------------------------

  describe "lease/2" do
    test "returns oldest pending task for agent" do
      {_pid, name} = start_queue()

      enqueue(name, "task_a", "agent_1", %{order: 1})
      Process.sleep(5)
      enqueue(name, "task_b", "agent_1", %{order: 2})

      assert {:ok, task} = lease(name, "agent_1")
      assert task.task_id == "task_a"
      assert task.status == :leased
      assert task.leased_by == "agent_1"
      assert %DateTime{} = task.leased_until
    end

    test "returns :empty when no tasks for agent" do
      {_pid, name} = start_queue()

      assert :empty = lease(name, "agent_nonexistent")
    end

    test "does not lease already-leased tasks" do
      {_pid, name} = start_queue()

      enqueue(name, "task_only", "agent_1", %{data: "test"})

      # First lease succeeds
      assert {:ok, _} = lease(name, "agent_1")

      # Second lease finds nothing pending
      assert :empty = lease(name, "agent_1")
    end

    test "does not lease tasks for a different agent" do
      {_pid, name} = start_queue()

      enqueue(name, "task_for_a", "agent_a", %{data: "test"})

      assert :empty = lease(name, "agent_b")
    end
  end

  # ---------------------------------------------------------------------------
  # complete
  # ---------------------------------------------------------------------------

  describe "complete/2" do
    test "sets status and result" do
      {_pid, name} = start_queue()

      enqueue(name, "task_c", "agent_1", %{action: "analyze"})
      {:ok, _} = lease(name, "agent_1")

      complete(name, "task_c", %{output: "analysis complete"})

      assert {:ok, task} = get_task(name, "task_c")
      assert task.status == :completed
      assert task.result == %{output: "analysis complete"}
      assert %DateTime{} = task.completed_at
      assert task.leased_until == nil
      assert task.leased_by == nil
    end
  end

  # ---------------------------------------------------------------------------
  # fail
  # ---------------------------------------------------------------------------

  describe "fail/2" do
    test "increments attempts" do
      {_pid, name} = start_queue()

      enqueue(name, "task_f", "agent_1", %{action: "risky"})
      {:ok, _} = lease(name, "agent_1")
      fail(name, "task_f", "connection timeout")

      assert {:ok, task} = get_task(name, "task_f")
      assert task.attempts == 1
    end

    test "sets pending again when under max_attempts" do
      {_pid, name} = start_queue()

      enqueue(name, "task_retry", "agent_1", %{action: "retry"}, max_attempts: 3)
      {:ok, _} = lease(name, "agent_1")
      fail(name, "task_retry", "temporary error")

      assert {:ok, task} = get_task(name, "task_retry")
      assert task.status == :pending
      assert task.attempts == 1
      assert task.error == "temporary error"
      assert task.leased_until == nil
    end

    test "sets :failed when max_attempts reached" do
      {_pid, name} = start_queue()

      enqueue(name, "task_final", "agent_1", %{action: "doomed"}, max_attempts: 2)

      # Attempt 1
      {:ok, _} = lease(name, "agent_1")
      fail(name, "task_final", "error 1")

      # Attempt 2 (max_attempts = 2, so this should finalize)
      {:ok, _} = lease(name, "agent_1")
      fail(name, "task_final", "error 2")

      assert {:ok, task} = get_task(name, "task_final")
      assert task.status == :failed
      assert task.attempts == 2
      assert task.error == "error 2"
    end
  end

  # ---------------------------------------------------------------------------
  # reap_expired_leases
  # ---------------------------------------------------------------------------

  describe "reap_expired_leases/0" do
    test "reverts expired leases to pending" do
      {_pid, name} = start_queue()

      enqueue(name, "task_expire", "agent_1", %{action: "slow"})

      # Lease with a very short duration (1ms)
      {:ok, _} = lease(name, "agent_1", 1)

      # Wait for it to expire
      Process.sleep(10)

      reap_expired(name)

      assert {:ok, task} = get_task(name, "task_expire")
      assert task.status == :pending
      assert task.leased_until == nil
      assert task.leased_by == nil
    end

    test "does not reap active leases" do
      {_pid, name} = start_queue()

      enqueue(name, "task_active", "agent_1", %{action: "working"})

      # Lease with a long duration (5 minutes)
      {:ok, _} = lease(name, "agent_1", 300_000)

      reap_expired(name)

      assert {:ok, task} = get_task(name, "task_active")
      assert task.status == :leased
    end
  end

  # ---------------------------------------------------------------------------
  # list_tasks
  # ---------------------------------------------------------------------------

  describe "list_tasks/1" do
    test "returns all tasks" do
      {_pid, name} = start_queue()

      enqueue(name, "t1", "agent_1", %{n: 1})
      enqueue(name, "t2", "agent_2", %{n: 2})

      tasks = list_tasks(name)
      assert length(tasks) == 2
    end

    test "filters by status" do
      {_pid, name} = start_queue()

      enqueue(name, "t_pending", "agent_1", %{n: 1})
      enqueue(name, "t_leased", "agent_1", %{n: 2})
      {:ok, _} = lease(name, "agent_1")

      pending = list_tasks(name, status: :pending)
      assert length(pending) == 1
      assert hd(pending).task_id == "t_leased"

      leased = list_tasks(name, status: :leased)
      assert length(leased) == 1
      assert hd(leased).task_id == "t_pending"
    end

    test "filters by agent_id" do
      {_pid, name} = start_queue()

      enqueue(name, "t_a1", "agent_a", %{n: 1})
      enqueue(name, "t_b1", "agent_b", %{n: 2})

      a_tasks = list_tasks(name, agent_id: "agent_a")
      assert length(a_tasks) == 1
      assert hd(a_tasks).agent_id == "agent_a"
    end
  end
end
