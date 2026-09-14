defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.HelperProbe do
  @moduledoc false

  # This invokes only a trusted helper's documented non-capture --check mode.
  # It is not a generic command runner and never adds permission-request flags.
  def check(path, expected, timeout \\ 7_000) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--check"]
      ])

    try do
      await(port, expected, "", System.monotonic_time(:millisecond) + timeout)
    after
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          # Check processes are ours, never a pre-existing desktop daemon.
          System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
          close(port)

        _ ->
          :ok
      end
    end
  rescue
    _ -> {:error, :helper_check_failed}
  end

  defp await(port, expected, output, deadline) do
    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= 16_384 ->
        await(port, expected, output <> data, deadline)

      {^port, {:data, _}} ->
        {:error, :helper_check_output_limit}

      {^port, {:exit_status, 0}} ->
        if expected in String.split(output, ~r/\r?\n/),
          do: :ok,
          else: {:error, :helper_check_protocol}

      {^port, {:exit_status, status}} ->
        {:error, {:helper_check_failed, status}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :helper_check_timeout}
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
