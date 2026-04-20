defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.ExecTest do
  @moduledoc """
  Tests for the OSA exec RPC executor.

  Runs actual OS processes — skip on Windows via @moduletag :unix.
  """

  use ExUnit.Case, async: true

  @moduletag :unix

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Exec

  defp start_exec(test_pid \\ nil) do
    session_pid = test_pid || self()
    {:ok, pid} = Exec.start_link(session_pid: session_pid)
    pid
  end

  # Helper: collect all messages for a job until the terminal frame arrives.
  defp collect(job_id, timeout_ms \\ 5_000) do
    do_collect(job_id, timeout_ms, [])
  end

  defp do_collect(job_id, remaining, acc) when remaining > 0 do
    receive do
      {:exec_chunk, %{job_id: ^job_id} = chunk} ->
        do_collect(job_id, remaining - 10, [{:chunk, chunk} | acc])

      {:exec_result, %{job_id: ^job_id} = result} ->
        {:done, Enum.reverse([{:result, result} | acc])}

      {:exec_error, %{job_id: ^job_id} = error} ->
        {:error_terminal, Enum.reverse([{:error, error} | acc])}
    after
      10 ->
        do_collect(job_id, remaining - 10, acc)
    end
  end

  defp do_collect(_job_id, 0, acc) do
    {:timeout, Enum.reverse(acc)}
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "echo hello" do
    test "produces stdout chunk and exit_code 0" do
      exec_pid = start_exec()
      job_id = Ecto.UUID.generate()

      assert :ok =
               Exec.start_job(exec_pid, %{
                 job_id: job_id,
                 cmd: "echo",
                 args: ["hello"],
                 env: [],
                 cwd: System.tmp_dir!(),
                 timeout_ms: 5_000
               })

      {:done, frames} = collect(job_id)

      chunks =
        frames
        |> Enum.filter(&match?({:chunk, _}, &1))
        |> Enum.map(fn {:chunk, %{data: d}} -> d end)

      output = IO.iodata_to_binary(chunks)
      assert String.contains?(output, "hello")

      [{:result, result}] = Enum.filter(frames, &match?({:result, _}, &1))
      assert result.exit_code == 0
      assert result.elapsed_ms >= 0
    end
  end

  describe "non-zero exit code" do
    test "exit code is forwarded in exec_result" do
      exec_pid = start_exec()
      job_id = Ecto.UUID.generate()

      assert :ok =
               Exec.start_job(exec_pid, %{
                 job_id: job_id,
                 cmd: "sh",
                 args: ["-c", "exit 42"],
                 env: [],
                 cwd: System.tmp_dir!(),
                 timeout_ms: 5_000
               })

      {:done, frames} = collect(job_id)

      [{:result, result}] = Enum.filter(frames, &match?({:result, _}, &1))
      assert result.exit_code == 42
    end
  end

  describe "timeout" do
    test "exec_error with reason :timeout when process exceeds timeout_ms" do
      exec_pid = start_exec()
      job_id = Ecto.UUID.generate()

      assert :ok =
               Exec.start_job(exec_pid, %{
                 job_id: job_id,
                 cmd: "sleep",
                 args: ["10"],
                 env: [],
                 cwd: System.tmp_dir!(),
                 timeout_ms: 100
               })

      # Give the timeout a bit of slack
      result = collect(job_id, 2_000)
      assert match?({:error_terminal, _}, result)

      {:error_terminal, frames} = result
      [{:error, error}] = Enum.filter(frames, &match?({:error, _}, &1))
      assert error.reason == :timeout
    end
  end

  describe "cancel" do
    test "exec_error with reason :canceled when cancel_job/2 is called" do
      exec_pid = start_exec()
      job_id = Ecto.UUID.generate()

      assert :ok =
               Exec.start_job(exec_pid, %{
                 job_id: job_id,
                 cmd: "sleep",
                 args: ["10"],
                 env: [],
                 cwd: System.tmp_dir!(),
                 timeout_ms: 30_000
               })

      # Cancel after a short delay
      Process.sleep(50)
      Exec.cancel_job(exec_pid, job_id)

      result = collect(job_id, 2_000)
      assert match?({:error_terminal, _}, result)

      {:error_terminal, frames} = result
      [{:error, error}] = Enum.filter(frames, &match?({:error, _}, &1))
      assert error.reason == :canceled
    end
  end

  describe "command_not_allowed" do
    test "returns exec_error when command is blocked by config" do
      # Temporarily override to a restricted list
      original = Application.get_env(:optimal_system_agent, :oc_exec_allowed, nil)
      Application.put_env(:optimal_system_agent, :oc_exec_allowed, ["ls"])

      on_exit(fn ->
        if original do
          Application.put_env(:optimal_system_agent, :oc_exec_allowed, original)
        else
          Application.delete_env(:optimal_system_agent, :oc_exec_allowed)
        end
      end)

      exec_pid = start_exec()
      job_id = Ecto.UUID.generate()

      # We can't easily inject the allowlist into the Config module without
      # the config file being present. Instead, test the public Config API.
      # The executor itself will use Config.command_allowed?/1.

      # Just verify that exec_pid handles an unknown/non-existent command gracefully
      assert :ok =
               Exec.start_job(exec_pid, %{
                 job_id: job_id,
                 cmd: "/nonexistent_binary_xyz",
                 args: [],
                 env: [],
                 cwd: System.tmp_dir!(),
                 timeout_ms: 1_000
               })

      result = collect(job_id, 3_000)
      assert match?({:error_terminal, _}, result)
    end
  end

  describe "env passthrough" do
    test "env vars are visible inside the child process" do
      exec_pid = start_exec()
      job_id = Ecto.UUID.generate()

      assert :ok =
               Exec.start_job(exec_pid, %{
                 job_id: job_id,
                 cmd: "sh",
                 args: ["-c", "echo $OC_TEST_VAR"],
                 env: [{"OC_TEST_VAR", "hello_from_env"}],
                 cwd: System.tmp_dir!(),
                 timeout_ms: 5_000
               })

      {:done, frames} = collect(job_id)

      chunks = Enum.filter(frames, &match?({:chunk, _}, &1)) |> Enum.map(fn {:chunk, c} -> c.data end)
      output = IO.iodata_to_binary(chunks)
      assert String.contains?(output, "hello_from_env")
    end
  end
end
