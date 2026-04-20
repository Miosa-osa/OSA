defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.ExecTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Exec

  defp run_job(job) do
    test_pid = self()
    reply = fn frame -> send(test_pid, {:reply, frame}) end

    child_spec = %{
      id: make_ref(),
      start: {Exec, :start_link, [job, reply]},
      restart: :temporary
    }

    {:ok, _pid} = start_supervised(child_spec)

    receive do
      {:reply, frame} -> frame
    after
      5_000 -> flunk("Exec did not reply within 5s")
    end
  end

  describe "Exec.start_link/2" do
    test "starts successfully" do
      test_pid = self()
      reply = fn frame -> send(test_pid, {:reply, frame}) end
      job = %{id: "j-start", kind: :exec_on_host, cmd: "true"}

      child_spec = %{
        id: :exec_start_test,
        start: {Exec, :start_link, [job, reply]},
        restart: :temporary
      }

      {:ok, pid} = start_supervised(child_spec)
      assert is_pid(pid)
    end
  end

  describe "exec success" do
    test "runs echo and returns job_done with exit_code 0" do
      job = %{id: "j-echo", kind: :exec_on_host, cmd: "echo hello"}
      frame = run_job(job)
      assert {:job_done, "j-echo", result} = frame
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "hello")
    end

    test "captures stdout" do
      job = %{id: "j-out", kind: :exec_on_host, cmd: "printf 'test output'"}
      frame = run_job(job)
      assert {:job_done, "j-out", result} = frame
      assert result.stdout == "test output"
    end

    test "returns duration_ms as non-negative integer" do
      job = %{id: "j-dur", kind: :exec_on_host, cmd: "true"}
      frame = run_job(job)
      assert {:job_done, "j-dur", result} = frame
      assert is_integer(result.duration_ms) and result.duration_ms >= 0
    end

    test "non-zero exit code is reflected in result" do
      job = %{id: "j-fail", kind: :exec_on_host, cmd: "exit 2"}
      frame = run_job(job)
      assert {:job_done, "j-fail", result} = frame
      assert result.exit_code == 2
    end
  end

  describe "empty command" do
    test "returns job_fail for empty cmd" do
      job = %{id: "j-empty", kind: :exec_on_host, cmd: ""}
      frame = run_job(job)
      assert {:job_fail, "j-empty", %{reason: :exec_error}} = frame
    end
  end

  describe "output cap" do
    test "caps output at 1 MB and appends truncation marker" do
      # Generate >1 MB of output
      job = %{
        id: "j-cap",
        kind: :exec_on_host,
        cmd: "dd if=/dev/zero bs=1024 count=1200 2>/dev/null | tr '\\0' 'a'"
      }

      frame = run_job(job)
      assert {:job_done, "j-cap", result} = frame
      # Output is either capped or full — never exceeds cap + marker
      assert byte_size(result.stdout) <= 1_048_576 + byte_size("\n...[output capped]")

      if byte_size(result.stdout) > 1_048_576 do
        assert String.ends_with?(result.stdout, "\n...[output capped]")
      end
    end
  end

  describe "timeout" do
    test "returns job_fail with :exec_error after timeout" do
      job = %{id: "j-timeout", kind: :exec_on_host, cmd: "sleep 60", timeout_ms: 50}
      frame = run_job(job)
      assert {:job_fail, "j-timeout", %{reason: :exec_error}} = frame
    end
  end
end
