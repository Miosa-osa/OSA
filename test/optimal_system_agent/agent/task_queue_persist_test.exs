defmodule OptimalSystemAgent.Agent.TaskQueuePersistTest do
  @moduledoc """
  The queue persisted best-effort but mutated memory unconditionally.

  `persist_update/2` swallowed every DB failure and returned the state
  unchanged — indistinguishable from success — and `complete`, `fail`, `lease`
  and the reaper then advanced the in-memory map regardless. A `complete` whose
  write failed left `tasks` saying `:completed` while the row still said
  `"leased"` with no result; on restart the reaper expires it and the task RUNS
  A SECOND TIME, with the first run's result gone.

  These tests force the failure by renaming the `task_queue` table away while
  the queue still believes the DB is available, so every Repo call genuinely
  raises.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.TaskQueue

  setup do
    start_supervised!(TaskQueue)
    :ok
  end

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Make every subsequent durable write fail the way a real one does: the queue
  # believes the DB is there, and the table is not. Renaming the table is the
  # least invasive way to produce a genuine adapter error rather than a mock.
  defp break_db do
    OptimalSystemAgent.Store.Repo.query!("ALTER TABLE task_queue RENAME TO task_queue_hidden")
    :sys.replace_state(TaskQueue, fn state -> %{state | db_available: true} end)
  end

  defp heal_db do
    :sys.replace_state(TaskQueue, fn state -> %{state | db_available: false} end)
    OptimalSystemAgent.Store.Repo.query!("ALTER TABLE task_queue_hidden RENAME TO task_queue")
  end

  defp fetch(id) do
    assert {:ok, task} = TaskQueue.get_task(id)
    task
  end

  describe "complete/3 with a failing durable write" do
    test "does not advance the task to :completed in memory" do
      id = uid("persist-complete")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{"work" => 1})
      {:ok, leased} = TaskQueue.lease(agent, 60_000)
      assert leased.task_id == id

      break_db()
      TaskQueue.complete(id, %{"out" => "done"}, agent_id: agent)
      # Flush the cast.
      task = fetch(id)
      heal_db()

      assert task.status == :leased,
             "memory advanced to :#{task.status} while the row still says leased with no " <>
               "result — the task re-runs after a restart and the result is lost"

      assert task.leased_by == agent
    end

    test "the same complete succeeds once the write can land" do
      id = uid("persist-retry")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{"work" => 1})
      {:ok, _} = TaskQueue.lease(agent, 60_000)

      break_db()
      TaskQueue.complete(id, %{"out" => "first try"}, agent_id: agent)
      _ = fetch(id)
      heal_db()

      # The holder still owns the lease, so a plain retry works.
      TaskQueue.complete(id, %{"out" => "second try"}, agent_id: agent)
      task = fetch(id)

      assert task.status == :completed
      assert task.result == %{"out" => "second try"}
    end
  end

  describe "fail/3 with a failing durable write" do
    test "does not release the lease or lose the attempts increment" do
      id = uid("persist-fail")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{"work" => 1}, max_attempts: 3)
      {:ok, _} = TaskQueue.lease(agent, 60_000)

      break_db()
      TaskQueue.fail(id, "boom", agent_id: agent)
      task = fetch(id)
      heal_db()

      assert task.status == :leased
      assert task.attempts == 0, "the attempts increment was applied without being persisted"
    end
  end

  describe "lease/2 with a failing durable write" do
    test "does not hand the work out" do
      id = uid("persist-lease")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{"work" => 1})

      break_db()
      result = TaskQueue.lease(agent, 60_000)
      heal_db()

      assert result == {:error, :persist_failed},
             "work was handed to a worker on the strength of a write that failed"

      assert fetch(id).status == :pending
    end
  end

  describe "enqueue_sync/4 with a failing durable write" do
    test "does not cache a task nobody durably recorded" do
      id = uid("persist-enqueue")
      agent = uid("agent")

      break_db()
      result = TaskQueue.enqueue_sync(id, agent, %{"work" => 1})
      heal_db()

      assert result == {:error, :persist_failed}
      assert TaskQueue.get_task(id) == {:error, :not_found}
    end
  end

  describe "the reaper with a failing durable write" do
    test "keeps the lease rather than freeing the task for a second worker" do
      id = uid("persist-reap")
      agent = uid("agent")

      {:ok, _} = TaskQueue.enqueue_sync(id, agent, %{"work" => 1}, max_attempts: 5)
      {:ok, _} = TaskQueue.lease(agent, 1)
      Process.sleep(10)

      break_db()
      TaskQueue.reap_expired_leases()
      task = fetch(id)
      heal_db()

      assert task.status == :leased,
             "the reaper returned the task to the pending pool while the row still shows it " <>
               "leased — it is now leased twice"

      # And it is still not available to a second worker.
      assert TaskQueue.lease(uid("other"), 60_000) != {:ok, task}
    end
  end
end
