defmodule OptimalSystemAgent.Tools.Builtins.TaskWriteCheckTest do
  @moduledoc """
  `task_write`'s acceptance-check surface: `add`/`update` with a `check`,
  `complete` refusing until it passes, `run_check` for a standalone verdict,
  and the permission gate on a `"command"`-type check (it shells out exactly
  like `shell_execute`, so it must not bypass that tool's permission policy).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.TaskWrite
  alias OptimalSystemAgent.Tools.Builtins.TaskWrite.Handler
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Agent.Tasks

  @session "test-task-write-check-#{:rand.uniform(100_000)}"

  setup do
    case GenServer.whereis(Tasks) do
      nil -> start_supervised!({Tasks, name: Tasks})
      _pid -> :ok
    end

    Tasks.clear_tasks(@session)

    on_exit(fn ->
      case GenServer.whereis(Tasks) do
        nil -> :ok
        _pid -> Tasks.clear_tasks(@session)
      end
    end)

    :ok
  end

  defp add_with_check(check) do
    {:ok, msg} =
      TaskWrite.execute(%{
        "action" => "add",
        "session_id" => @session,
        "title" => "checked task",
        "check" => check
      })

    [id] = Regex.run(~r/Created task (\w+)/, msg, capture: :all_but_first)
    id
  end

  describe "add with a check" do
    test "the task is created with a pending check" do
      id = add_with_check(%{"type" => "command", "command" => "true"})
      [task] = Tasks.get_tasks(@session)
      assert task.id == id
      assert task.check.status == "pending"
      assert task.check.type == "command"
    end
  end

  describe "complete — gated by the check" do
    test "refuses and reports the failure output" do
      id = add_with_check(%{"type" => "command", "command" => "echo boom && false"})

      assert {:error, message} =
               TaskWrite.execute(%{
                 "action" => "complete",
                 "session_id" => @session,
                 "task_id" => id
               })

      assert message =~ "NOT completed"
      assert message =~ "boom"
    end

    test "succeeds once the check passes" do
      id = add_with_check(%{"type" => "command", "command" => "true"})

      assert {:ok, message} =
               TaskWrite.execute(%{
                 "action" => "complete",
                 "session_id" => @session,
                 "task_id" => id
               })

      assert message =~ "Completed"
      [task] = Tasks.get_tasks(@session)
      assert task.status == :completed
    end
  end

  describe "run_check action" do
    test "reports the verdict without completing" do
      id = add_with_check(%{"type" => "command", "command" => "echo hello"})

      assert {:ok, message} =
               TaskWrite.execute(%{
                 "action" => "run_check",
                 "session_id" => @session,
                 "task_id" => id
               })

      assert message =~ "passed"
      assert message =~ "hello"

      [task] = Tasks.get_tasks(@session)
      assert task.status == :pending
    end

    test "errors clearly for a task with no check" do
      {:ok, msg} =
        TaskWrite.execute(%{"action" => "add", "session_id" => @session, "title" => "plain"})

      [id] = Regex.run(~r/Created task (\w+)/, msg, capture: :all_but_first)

      assert {:error, message} =
               TaskWrite.execute(%{
                 "action" => "run_check",
                 "session_id" => @session,
                 "task_id" => id
               })

      assert message =~ "no acceptance check"
    end
  end

  describe "check_permissions/2 — command-type checks route through shell_execute's gate" do
    test "a checkless task, or any non-command action, is always allowed" do
      assert Handler.check_permissions(%{"action" => "list"}, %UseContext{session_id: @session}) ==
               {:allow, %{"action" => "list"}}
    end

    test "a safe command check is allowed" do
      id = add_with_check(%{"type" => "command", "command" => "echo hi"})
      input = %{"action" => "complete", "session_id" => @session, "task_id" => id}

      assert {:allow, ^input} =
               Handler.check_permissions(input, %UseContext{session_id: @session})
    end

    test "a risky command check (matches shell_execute's ask tier) is asked, not silently allowed" do
      id = add_with_check(%{"type" => "command", "command" => "sudo apt-get update"})
      input = %{"action" => "complete", "session_id" => @session, "task_id" => id}

      assert {:ask, _reason} = Handler.check_permissions(input, %UseContext{session_id: @session})
    end

    test "a catastrophic command check is denied outright" do
      id = add_with_check(%{"type" => "command", "command" => "rm -rf /"})
      input = %{"action" => "run_check", "session_id" => @session, "task_id" => id}

      assert {:deny, _reason} =
               Handler.check_permissions(input, %UseContext{session_id: @session})
    end

    test "a file_exists / symbol_exists check never asks — it doesn't shell out" do
      id = add_with_check(%{"type" => "file_exists", "path" => "/tmp/whatever"})
      input = %{"action" => "complete", "session_id" => @session, "task_id" => id}

      assert {:allow, ^input} =
               Handler.check_permissions(input, %UseContext{session_id: @session})
    end
  end
end
