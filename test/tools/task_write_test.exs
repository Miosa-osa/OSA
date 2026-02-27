defmodule OptimalSystemAgent.Tools.Builtins.TaskWriteTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.TaskWrite
  alias OptimalSystemAgent.Agent.TaskTracker

  @session "test-task-write-#{:rand.uniform(100_000)}"

  setup do
    # TaskTracker is started by the supervision tree.
    # If not running (e.g., isolated test), start it.
    case GenServer.whereis(TaskTracker) do
      nil -> start_supervised!({TaskTracker, name: TaskTracker})
      _pid -> :ok
    end

    # Clear any leftover tasks for our test session
    TaskTracker.clear_tasks(@session)
    on_exit(fn -> TaskTracker.clear_tasks(@session) end)
    :ok
  end

  describe "name/0" do
    test "returns task_write" do
      assert TaskWrite.name() == "task_write"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      assert is_binary(TaskWrite.description())
      assert String.length(TaskWrite.description()) > 0
    end
  end

  describe "parameters/0" do
    test "returns valid JSON Schema" do
      params = TaskWrite.parameters()
      assert params["type"] == "object"
      assert is_map(params["properties"])
      assert "action" in params["required"]
    end
  end

  describe "execute/1 — add" do
    test "adds a single task" do
      assert {:ok, msg} = TaskWrite.execute(%{"action" => "add", "session_id" => @session, "title" => "Set up database"})
      assert msg =~ "Created task"
      assert msg =~ "Set up database"
    end

    test "returns error when title missing" do
      assert {:error, _} = TaskWrite.execute(%{"action" => "add", "session_id" => @session})
    end
  end

  describe "execute/1 — add_multiple" do
    test "adds multiple tasks" do
      titles = ["Step 1", "Step 2", "Step 3"]
      assert {:ok, msg} = TaskWrite.execute(%{"action" => "add_multiple", "session_id" => @session, "titles" => titles})
      assert msg =~ "Created 3 tasks"
    end

    test "returns error when titles missing" do
      assert {:error, _} = TaskWrite.execute(%{"action" => "add_multiple", "session_id" => @session})
    end

    test "returns error when titles empty" do
      assert {:error, _} = TaskWrite.execute(%{"action" => "add_multiple", "session_id" => @session, "titles" => []})
    end
  end

  describe "execute/1 — start/complete/fail" do
    setup do
      {:ok, id} = TaskTracker.add_task(@session, "Test task")
      %{task_id: id}
    end

    test "starts a task", %{task_id: id} do
      assert {:ok, msg} = TaskWrite.execute(%{"action" => "start", "session_id" => @session, "task_id" => id})
      assert msg =~ "Started task #{id}"
    end

    test "completes a task", %{task_id: id} do
      assert {:ok, msg} = TaskWrite.execute(%{"action" => "complete", "session_id" => @session, "task_id" => id})
      assert msg =~ "Completed task #{id}"
    end

    test "fails a task with reason", %{task_id: id} do
      assert {:ok, msg} = TaskWrite.execute(%{
        "action" => "fail",
        "session_id" => @session,
        "task_id" => id,
        "reason" => "timeout"
      })
      assert msg =~ "Failed task #{id}"
      assert msg =~ "timeout"
    end

    test "returns error for non-existent task" do
      assert {:error, _} = TaskWrite.execute(%{"action" => "start", "session_id" => @session, "task_id" => "nonexistent"})
    end

    test "returns error when task_id missing" do
      assert {:error, _} = TaskWrite.execute(%{"action" => "start", "session_id" => @session})
      assert {:error, _} = TaskWrite.execute(%{"action" => "complete", "session_id" => @session})
      assert {:error, _} = TaskWrite.execute(%{"action" => "fail", "session_id" => @session})
    end
  end

  describe "execute/1 — list" do
    test "lists empty tasks" do
      assert {:ok, msg} = TaskWrite.execute(%{"action" => "list", "session_id" => @session})
      assert msg == "No tasks."
    end

    test "lists tasks with statuses" do
      {:ok, id1} = TaskTracker.add_task(@session, "First task")
      {:ok, _id2} = TaskTracker.add_task(@session, "Second task")
      TaskTracker.start_task(@session, id1)

      assert {:ok, msg} = TaskWrite.execute(%{"action" => "list", "session_id" => @session})
      assert msg =~ "Tasks (0/2 completed)"
      assert msg =~ "First task"
      assert msg =~ "Second task"
      assert msg =~ "[in_progress]"
    end
  end

  describe "execute/1 — clear" do
    test "clears all tasks" do
      TaskTracker.add_task(@session, "Task to clear")
      assert {:ok, msg} = TaskWrite.execute(%{"action" => "clear", "session_id" => @session})
      assert msg == "Cleared all tasks"

      tasks = TaskTracker.get_tasks(@session)
      assert tasks == []
    end
  end

  describe "execute/1 — unknown action" do
    test "returns error for unknown action" do
      assert {:error, msg} = TaskWrite.execute(%{"action" => "unknown", "session_id" => @session})
      assert msg =~ "Unknown action"
    end
  end

  describe "execute/1 — missing action" do
    test "returns error when action missing" do
      assert {:error, _} = TaskWrite.execute(%{})
    end
  end

  describe "execute/1 — default session_id" do
    test "uses default session when session_id omitted" do
      assert {:ok, _} = TaskWrite.execute(%{"action" => "add", "title" => "Default session task"})
      assert {:ok, msg} = TaskWrite.execute(%{"action" => "list"})
      assert msg =~ "Default session task"

      # Cleanup
      TaskWrite.execute(%{"action" => "clear"})
    end
  end

  describe "format_task_list/1" do
    test "formats empty list" do
      assert TaskWrite.format_task_list([]) == "No tasks."
    end

    test "formats mixed statuses" do
      tasks = [
        %{id: "001", title: "Done task", status: :completed, reason: nil},
        %{id: "002", title: "Active task", status: :in_progress, reason: nil},
        %{id: "003", title: "Pending task", status: :pending, reason: nil},
        %{id: "004", title: "Failed task", status: :failed, reason: "timeout"}
      ]

      result = TaskWrite.format_task_list(tasks)
      assert result =~ "Tasks (1/4 completed)"
      assert result =~ "✔ 001: Done task"
      assert result =~ "◼ 002: Active task"
      assert result =~ "◻ 003: Pending task"
      assert result =~ "✘ 004: Failed task"
      assert result =~ "[failed: timeout]"
    end
  end
end
