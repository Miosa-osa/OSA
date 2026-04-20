defmodule OptimalSystemAgent.OpenComputers.ExecutorTest do
  # async: false required because we register/unregister the global
  # Executor.Supervisor name in setup.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor
  alias OptimalSystemAgent.OpenComputers.Executor.Supervisor, as: ExecSup

  setup do
    # Start a DynamicSupervisor and register it under the well-known name so
    # Executor.dispatch/2 can find it without any source changes.
    # On teardown the ExUnit supervision tree stops the process, which
    # automatically unregisters the name.
    {:ok, sup} =
      start_supervised(%{
        id: ExecSup,
        start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: ExecSup]]}
      })

    {:ok, sup: sup}
  end

  describe "dispatch/2 — known kinds" do
    test "dispatches :exec_on_host and returns :ok" do
      test_pid = self()
      reply = fn frame -> send(test_pid, {:executor_frame, frame}) end
      job = %{id: "d-exec", kind: :exec_on_host, cmd: "echo dispatched"}
      assert :ok = Executor.dispatch(job, reply)
    end

    test "dispatches :dispatch_agent and returns :ok" do
      reply = fn _frame -> :ok end
      job = %{id: "d-agent", kind: :dispatch_agent}
      assert :ok = Executor.dispatch(job, reply)
    end

    test "dispatches :stream_native_desktop and returns :ok" do
      reply = fn _frame -> :ok end
      job = %{id: "d-desktop", kind: :stream_native_desktop}
      assert :ok = Executor.dispatch(job, reply)
    end

    test "exec job eventually sends job_done reply" do
      test_pid = self()
      reply = fn frame -> send(test_pid, {:executor_reply, frame}) end
      job = %{id: "d-reply", kind: :exec_on_host, cmd: "echo ok"}
      :ok = Executor.dispatch(job, reply)

      assert_receive {:executor_reply, {:job_done, "d-reply", _result}}, 5_000
    end
  end

  describe "dispatch/2 — unknown kind" do
    test "returns {:error, :unsupported_kind} for unknown atom" do
      test_pid = self()
      reply = fn frame -> send(test_pid, {:fail_frame, frame}) end
      job = %{id: "d-unknown", kind: :totally_bogus}
      assert {:error, :unsupported_kind} = Executor.dispatch(job, reply)
    end

    test "calls reply with job_fail for unknown kind" do
      test_pid = self()
      reply = fn frame -> send(test_pid, {:fail_frame, frame}) end
      job = %{id: "d-unk2", kind: :no_such_executor}
      Executor.dispatch(job, reply)
      assert_receive {:fail_frame, {:job_fail, "d-unk2", %{reason: :unsupported_kind}}}, 1_000
    end

    test "unknown binary kind string raises or returns error" do
      reply = fn _frame -> :ok end

      unique_kind =
        "osa_executor_no_such_kind_xyz_#{System.unique_integer([:positive])}"

      job = %{id: "d-str", kind: unique_kind}

      # The executor calls String.to_existing_atom which raises ArgumentError for
      # atoms not in the atom table. Either outcome (exception or {:error, _}) is acceptable.
      result =
        try do
          Executor.dispatch(job, reply)
        rescue
          ArgumentError -> {:error, :unsupported_kind}
        end

      assert match?({:error, _}, result)
    end
  end
end
