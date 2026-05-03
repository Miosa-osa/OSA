defmodule OptimalSystemAgent.Agent.TurnQueueTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.TurnQueue

  setup do
    queue = :"turn_queue_#{System.unique_integer([:positive])}"
    supervisor = :"turn_queue_sup_#{System.unique_integer([:positive])}"

    start_supervised!({Task.Supervisor, name: supervisor})
    start_supervised!({TurnQueue, name: queue})

    %{queue: queue, supervisor: supervisor}
  end

  test "runs one turn per session and starts queued turns after completion", %{
    queue: queue,
    supervisor: supervisor
  } do
    parent = self()

    process_fun = fn _session_id, message, _opts ->
      send(parent, {:started, message, self()})

      receive do
        :release -> {:ok, message}
      after
        1_000 -> {:error, :timeout}
      end
    end

    assert {:ok, first} =
             TurnQueue.enqueue("session-a", "first",
               queue: queue,
               task_supervisor: supervisor,
               process_fun: process_fun
             )

    assert first.status == "processing"
    assert first.queue_depth == 0
    assert_receive {:started, "first", first_pid}

    assert {:ok, second} =
             TurnQueue.enqueue("session-a", "second",
               queue: queue,
               task_supervisor: supervisor,
               process_fun: process_fun
             )

    assert second.status == "queued"
    assert second.queue_depth == 1
    refute_receive {:started, "second", _}, 50

    assert %{active: true, queue_depth: 1} = TurnQueue.status("session-a", queue: queue)

    send(first_pid, :release)
    assert_receive {:started, "second", second_pid}

    assert %{active: true, queue_depth: 0} = TurnQueue.status("session-a", queue: queue)

    send(second_pid, :release)

    eventually(fn ->
      assert %{active: false, queue_depth: 0} = TurnQueue.status("session-a", queue: queue)
    end)
  end

  test "different sessions can run in parallel", %{queue: queue, supervisor: supervisor} do
    parent = self()

    process_fun = fn session_id, message, _opts ->
      send(parent, {:started, session_id, message, self()})

      receive do
        :release -> {:ok, message}
      after
        1_000 -> {:error, :timeout}
      end
    end

    assert {:ok, %{status: "processing"}} =
             TurnQueue.enqueue("session-a", "a",
               queue: queue,
               task_supervisor: supervisor,
               process_fun: process_fun
             )

    assert {:ok, %{status: "processing"}} =
             TurnQueue.enqueue("session-b", "b",
               queue: queue,
               task_supervisor: supervisor,
               process_fun: process_fun
             )

    assert_receive {:started, "session-a", "a", pid_a}
    assert_receive {:started, "session-b", "b", pid_b}

    send(pid_a, :release)
    send(pid_b, :release)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    try do
      fun.()
    rescue
      ExUnit.AssertionError ->
        Process.sleep(25)
        eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: fun.()
end
