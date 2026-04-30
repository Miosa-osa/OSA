defmodule OptimalSystemAgent.Agent.Scheduler.HeartbeatExecutorTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Scheduler.HeartbeatExecutor

  defp start_executor do
    name = :"hb_exec_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(HeartbeatExecutor, [], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {pid, name}
  end

  describe "init/1" do
    test "starts with empty state" do
      {pid, _} = start_executor()
      assert Process.alive?(pid)
    end
  end

  describe "get_run/1" do
    test "returns nil for unknown run" do
      {_, name} = start_executor()
      assert GenServer.call(name, {:get_run, "nonexistent"}) == nil
    end
  end

  describe "list_runs/2" do
    test "returns empty list for unknown task" do
      {_, name} = start_executor()
      runs = GenServer.call(name, {:list_runs, "unknown_task", []})
      assert runs == []
    end
  end

  describe "execute/2" do
    test "rejects concurrent execution for same agent" do
      {_, name} = start_executor()

      # Manually insert a lock
      :sys.replace_state(name, fn state ->
        %{state | locks: Map.put(state.locks, "test_agent", true)}
      end)

      task = %{"id" => "t1", "name" => "test_agent", "job" => "test"}
      result = GenServer.call(name, {:execute, task, :manual})
      assert result == {:error, :locked}
    end

    test "executes command tasks through the scheduler executor" do
      {_, name} = start_executor()

      task = %{
        "id" => "cmd-task",
        "name" => "command task",
        "type" => "command",
        "command" => "printf scheduled-ok"
      }

      assert {:ok, run} = GenServer.call(name, {:execute, task, :manual})
      assert run.status == "succeeded"
      assert run.stdout == "scheduled-ok"
      assert run.scheduled_task_id == "cmd-task"
    end

    test "fails blocked command tasks without executing them" do
      {_, name} = start_executor()

      task = %{
        "id" => "blocked-command-task",
        "name" => "blocked command task",
        "type" => "command",
        "command" => "rm -rf /"
      }

      assert {:error, run} = GenServer.call(name, {:execute, task, :manual})
      assert run.status == "failed"
      assert run.error_message =~ "Blocked"
    end
  end

  describe "module definition" do
    test "exports start_link/1" do
      funs = HeartbeatExecutor.__info__(:functions)
      assert Enum.any?(funs, fn {name, _} -> name == :start_link end)
    end

    test "exports execute/2" do
      assert function_exported?(HeartbeatExecutor, :execute, 2)
    end

    test "exports get_run/1" do
      assert function_exported?(HeartbeatExecutor, :get_run, 1)
    end

    test "exports list_runs/2" do
      assert function_exported?(HeartbeatExecutor, :list_runs, 2)
    end
  end
end
