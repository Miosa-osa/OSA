defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Exec do
  @moduledoc """
  Executor for `:exec_on_host` — direct-mode shell exec on the host OS.

  Phase 1: captures combined stdout to a bounded size (1 MB), returns
  on exit with exit_code + duration. Streaming output per-line is
  Phase 2 work.
  """

  use GenServer, restart: :temporary
  require Logger

  @default_timeout_ms 30_000
  @max_output_bytes 1_048_576

  def start_link(job, reply) when is_map(job) and is_function(reply, 1) do
    GenServer.start_link(__MODULE__, {job, reply})
  end

  @impl true
  def init({job, reply}) do
    send(self(), :run)
    {:ok, %{job: job, reply: reply}}
  end

  @impl true
  def handle_info(:run, %{job: job, reply: reply} = state) do
    case run_command(job) do
      {:ok, %{exit_code: code, stdout: out, stderr: err, duration_ms: dur}} ->
        reply.(
          {:job_done, job.id,
           %{exit_code: code, stdout: out, stderr: err, duration_ms: dur}}
        )

      {:error, reason} ->
        reply.({:job_fail, job.id, %{reason: :exec_error, message: inspect(reason)}})
    end

    {:stop, :normal, state}
  end

  defp run_command(job) do
    cmd = Map.get(job, :cmd, "")
    cwd = Map.get(job, :cwd) || System.tmp_dir!()
    timeout = Map.get(job, :timeout_ms, @default_timeout_ms)
    env = Map.get(job, :env, %{}) |> Map.new(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    if cmd == "" or not is_binary(cmd) do
      {:error, :empty_command}
    else
      start = System.monotonic_time(:millisecond)

      task =
        Task.async(fn ->
          System.cmd("sh", ["-c", cmd], cd: cwd, env: Map.to_list(env), stderr_to_stdout: false)
        end)

      case Task.yield(task, timeout) do
        {:ok, {out, exit_code}} ->
          {:ok,
           %{
             exit_code: exit_code,
             stdout: cap(out),
             stderr: "",
             duration_ms: System.monotonic_time(:millisecond) - start
           }}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}

        {:exit, reason} ->
          {:error, {:task_exit, reason}}
      end
    end
  end

  defp cap(bin) when is_binary(bin) do
    if byte_size(bin) > @max_output_bytes do
      binary_part(bin, 0, @max_output_bytes) <> "\n...[output capped]"
    else
      bin
    end
  end
end
