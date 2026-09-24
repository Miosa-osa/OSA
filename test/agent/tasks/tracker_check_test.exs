defmodule OptimalSystemAgent.Agent.Tasks.TrackerCheckTest do
  @moduledoc """
  Acceptance-check gating on `Tracker.complete_task/3`: an item is only
  marked done when its check passes, run by the harness — never asserted by
  the model. See `tracker_test.exs`'s moduledoc for why every test gets its
  own throwaway `OSA_HOME`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Tasks

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_tracker_check_t#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", tmp)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp start_tracker do
    name = :"tracker_check_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Tasks.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, name}
  end

  defp session_id, do: "test_tracker_check_#{System.unique_integer([:positive, :monotonic])}"

  describe "complete_task/3 with no check" do
    test "completes exactly as before this feature existed" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "no check here", %{}, name)

      assert Tasks.complete_task(sid, id, name) == :ok
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :completed
    end
  end

  describe "complete_task/3 with a check" do
    test "refuses to complete when the check fails, and records the verdict" do
      {_pid, name} = start_tracker()
      sid = session_id()

      {:ok, id} =
        Tasks.add_task(
          sid,
          "must pass",
          %{check: %{"type" => "command", "command" => "false"}},
          name
        )

      assert {:error, {:check_failed, _output}} = Tasks.complete_task(sid, id, name)

      [task] = Tasks.get_tasks(sid, name)
      assert task.status != :completed
      assert task.check.status == "failed"
    end

    test "completes when the check passes" do
      {_pid, name} = start_tracker()
      sid = session_id()

      {:ok, id} =
        Tasks.add_task(
          sid,
          "must pass",
          %{check: %{"type" => "command", "command" => "true"}},
          name
        )

      assert Tasks.complete_task(sid, id, name) == :ok

      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :completed
      assert task.check.status == "passed"
    end

    test "a file_exists check gates completion on real file state" do
      {_pid, name} = start_tracker()
      sid = session_id()

      tmp_file =
        Path.join(System.tmp_dir!(), "osa_check_gate_#{System.unique_integer([:positive])}")

      {:ok, id} =
        Tasks.add_task(
          sid,
          "file must exist",
          %{check: %{"type" => "file_exists", "path" => tmp_file}},
          name
        )

      assert {:error, {:check_failed, _}} = Tasks.complete_task(sid, id, name)

      File.write!(tmp_file, "now it exists")
      on_exit(fn -> File.rm(tmp_file) end)

      assert Tasks.complete_task(sid, id, name) == :ok
    end

    test "the model's own claim of completion is not enough — retrying after a fix works" do
      {_pid, name} = start_tracker()
      sid = session_id()

      {:ok, id} =
        Tasks.add_task(
          sid,
          "flaky",
          %{check: %{"type" => "command", "command" => "test -f /tmp/osa_check_flag_missing"}},
          name
        )

      # First attempt: the model calls `complete`, asserting it is done. The
      # harness disagrees.
      assert {:error, {:check_failed, _}} = Tasks.complete_task(sid, id, name)
      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :in_progress or task.status == :pending
    end
  end

  describe "run_check/3" do
    test "runs the check WITHOUT completing the task" do
      {_pid, name} = start_tracker()
      sid = session_id()

      {:ok, id} =
        Tasks.add_task(
          sid,
          "check me",
          %{check: %{"type" => "command", "command" => "true"}},
          name
        )

      assert {:ok, check} = Tasks.run_check(sid, id, name)
      assert check.status == "passed"

      [task] = Tasks.get_tasks(sid, name)
      assert task.status == :pending
      assert task.check.status == "passed"
    end

    test "returns :no_check for a task without one" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "plain", %{}, name)

      assert Tasks.run_check(sid, id, name) == {:error, :no_check}
    end

    test "returns :not_found for an unknown task" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert Tasks.run_check(sid, "nope", name) == {:error, :not_found}
    end
  end

  describe "plan_progress/2" do
    test "a checkless completed task counts as passed" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "plain", %{}, name)
      Tasks.complete_task(sid, id, name)

      assert Tasks.plan_progress(sid, name) == %{passed: 1, total: 1, fraction: 1.0}
    end

    test "a checked task counts as passed only when its check has passed" do
      {_pid, name} = start_tracker()
      sid = session_id()

      {:ok, id} =
        Tasks.add_task(
          sid,
          "checked",
          %{check: %{"type" => "command", "command" => "false"}},
          name
        )

      assert Tasks.plan_progress(sid, name) == %{passed: 0, total: 1, fraction: 0.0}

      Tasks.run_check(sid, id, name)
      assert Tasks.plan_progress(sid, name) == %{passed: 0, total: 1, fraction: 0.0}
    end

    test "a mix of checked and checkless items computes a real fraction" do
      {_pid, name} = start_tracker()
      sid = session_id()

      {:ok, plain_id} = Tasks.add_task(sid, "plain", %{}, name)

      {:ok, checked_id} =
        Tasks.add_task(
          sid,
          "checked",
          %{check: %{"type" => "command", "command" => "true"}},
          name
        )

      {:ok, _pending_id} = Tasks.add_task(sid, "still pending", %{}, name)

      Tasks.complete_task(sid, plain_id, name)
      Tasks.complete_task(sid, checked_id, name)

      assert Tasks.plan_progress(sid, name) == %{
               passed: 2,
               total: 3,
               fraction: 2 / 3
             }
    end

    test "an empty checklist reports full fraction (nothing outstanding)" do
      {_pid, name} = start_tracker()
      sid = session_id()
      assert Tasks.plan_progress(sid, name) == %{passed: 0, total: 0, fraction: 1.0}
    end
  end

  describe "update_task_fields/4 with :check" do
    test "attaching a check to an existing task starts it at pending, and gates completion" do
      {_pid, name} = start_tracker()
      sid = session_id()
      {:ok, id} = Tasks.add_task(sid, "no check yet", %{}, name)

      :ok =
        Tasks.update_task_fields(
          sid,
          id,
          %{check: %{"type" => "command", "command" => "false"}},
          name
        )

      [task] = Tasks.get_tasks(sid, name)
      assert task.check.status == "pending"

      # The newly-attached (failing) check now gates completion, where before
      # attaching it `complete_task/3` would have succeeded unconditionally.
      assert {:error, {:check_failed, _}} = Tasks.complete_task(sid, id, name)
    end
  end
end
