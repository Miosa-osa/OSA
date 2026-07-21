defmodule OptimalSystemAgent.MCP.Transport.StdioReapingTest do
  @moduledoc """
  Integration test for descendant-process reaping (grok `SafeTokioChildProcess`).

  A stdio MCP server is typically launched via a wrapper (`npx` → `node`), so
  the direct child forks grandchildren. Here the "server" is a shell that forks
  a long `sleep` grandchild; on transport teardown the whole process group must
  be `killpg`ed so the grandchild does NOT orphan and leak.

  Linux-only: relies on `setsid` (+ `/proc`-style `kill -0` liveness). Skipped
  where `setsid` is unavailable (e.g. a bare macOS box), where the transport
  intentionally degrades to direct-child-only cleanup.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Transport.Stdio

  @moduletag :linux_only

  setup do
    if System.find_executable("setsid") do
      # Isolate the MCP stderr log under a throwaway config dir so the real
      # ~/.osa is never touched by the child-stderr redirect.
      tmp = Path.join(System.tmp_dir!(), "osa_reap_cfg_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:optimal_system_agent, :config_dir)
      Application.put_env(:optimal_system_agent, :config_dir, tmp)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :config_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :config_dir)

        File.rm_rf(tmp)
      end)

      :ok
    else
      {:skip, "setsid unavailable — reaping degrades to direct-child cleanup"}
    end
  end

  test "teardown killpg's the whole group, reaping grandchildren" do
    pidfile = Path.join(System.tmp_dir!(), "osa_reap_#{System.unique_integer([:positive])}.pid")
    on_exit(fn -> File.rm(pidfile) end)

    # sh (group leader) forks a `sleep` grandchild, records its pid, then waits
    # so the group stays alive until we tear the transport down.
    script = "sleep 300 & echo $! > #{pidfile}; wait"

    {:ok, transport} =
      Stdio.start_link(
        owner: self(),
        ref: make_ref(),
        name: "reap_test",
        command: "sh",
        args: ["-c", script]
      )

    # Wait for the grandchild pid to be recorded.
    assert grandchild = wait_for_pid(pidfile)
    assert alive?(grandchild), "grandchild should be running before teardown"

    # Give the pgid-probe timer a beat to cache the group, then tear down.
    Process.sleep(300)
    ref = Process.monitor(transport)
    # The transport may already be tearing itself down (it reaps its process
    # group on terminate regardless of who triggers it) — tolerate the race
    # where it's already gone. The real assertion is that the grandchild is
    # reaped, checked below via the monitor DOWN + liveness.
    if Process.alive?(transport) do
      try do
        GenServer.stop(transport)
      catch
        :exit, _ -> :ok
      end
    end
    assert_receive {:DOWN, ^ref, :process, ^transport, _}, 2_000

    # The grandchild must be reaped (killpg), not orphaned.
    assert wait_until(fn -> not alive?(grandchild) end),
           "grandchild #{grandchild} was orphaned instead of reaped"
  end

  defp wait_for_pid(pidfile, retries \\ 50) do
    case File.read(pidfile) do
      {:ok, contents} ->
        case contents |> String.trim() |> Integer.parse() do
          {_pid, _} -> String.trim(contents)
          :error -> retry_pid(pidfile, retries)
        end

      _ ->
        retry_pid(pidfile, retries)
    end
  end

  defp retry_pid(_pidfile, 0), do: nil

  defp retry_pid(pidfile, retries) do
    Process.sleep(20)
    wait_for_pid(pidfile, retries - 1)
  end

  # A process is alive iff `kill -0 <pid>` succeeds.
  defp alive?(pid) when is_binary(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  defp wait_until(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries <= 0 -> false
      true ->
        Process.sleep(20)
        wait_until(fun, retries - 1)
    end
  end
end
