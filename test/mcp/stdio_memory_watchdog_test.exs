defmodule OptimalSystemAgent.MCP.Transport.StdioMemoryWatchdogTest do
  @moduledoc """
  An MCP server is an arbitrary third-party program that OSA spawns and keeps
  alive for the whole session. Nothing bounded how large one could get.

  Measured on a real machine: an `axon serve --watch` MCP child grew at
  3.17 GB/hour and reached ~103 GB, at which point macOS began Jetsam-killing
  applications and the host had to be force-restarted. OSA did not write the
  leak, but it hosted it unbounded - which is the part it owns.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Transport.Stdio

  @keys [:mcp_memory_soft_mb, :mcp_memory_hard_mb, :mcp_memory_check_ms]

  setup do
    previous = Enum.map(@keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
        {k, :error} -> Application.delete_env(:optimal_system_agent, k)
      end)
    end)

    :ok
  end

  describe "thresholds" do
    test "a server at or past the limit trips it" do
      assert Stdio.exceeds?(6_144, 6_144)
      assert Stdio.exceeds?(103_000, 6_144)
    end

    test "a server under the limit does not" do
      refute Stdio.exceeds?(120, 6_144)
      refute Stdio.exceeds?(6_143, 6_144)
    end

    test "a nil limit disables that ceiling rather than tripping on everything" do
      # The failure to avoid: reading a disabled limit as 0 and restarting every
      # MCP server on its first sample.
      refute Stdio.exceeds?(103_000, nil)
      refute Stdio.exceeds?(0, nil)
    end
  end

  describe "defaults" do
    test "the hard ceiling is well above a healthy server but far below the host" do
      Application.delete_env(:optimal_system_agent, :mcp_memory_hard_mb)
      hard = Stdio.memory_hard_mb()

      # Real servers measured on this machine sit at 80-170 MB; the leaker was
      # 103_000 MB. The ceiling has to clear the former and catch the latter
      # long before a 96 GB host is exhausted.
      assert hard > 1_000, "#{hard} MB would restart healthy servers"
      assert hard < 32_000, "#{hard} MB is too close to exhausting the host"
    end

    test "the soft warning comes before the hard stop" do
      Application.delete_env(:optimal_system_agent, :mcp_memory_soft_mb)
      Application.delete_env(:optimal_system_agent, :mcp_memory_hard_mb)

      assert Stdio.memory_soft_mb() < Stdio.memory_hard_mb(),
             "the warning must arrive with room to act on it"
    end

    test "the watchdog can be switched off entirely" do
      Application.put_env(:optimal_system_agent, :mcp_memory_check_ms, nil)
      refute is_integer(Stdio.memory_check_ms())
    end
  end

  describe "measuring a real child" do
    setup do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["30"]])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      on_exit(fn ->
        System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)

        try do
          if is_port(port), do: Port.close(port)
        catch
          _, _ -> :ok
        end
      end)

      {:ok, port: port}
    end

    test "reports the resident size of a live process", %{port: port} do
      mb = Stdio.child_rss_mb(%{port: port, pgid: nil})

      assert is_integer(mb), "no measurement for a live child"
      assert mb >= 0
      assert mb < 1_000, "sleep(1) should not be measured at #{mb} MB"
    end
  end

  describe "when there is nothing to measure" do
    test "a dead process yields no sample rather than crashing" do
      # `ps` exits non-zero for an unknown pid. That must read as "no sample",
      # not as an exception inside the watchdog tick.
      assert Stdio.rss_kb_for(%{pgid: 999_999, port: nil}) in [nil, 0]
    end

    test "a state with neither a group nor a port yields no sample" do
      assert Stdio.rss_kb_for(%{}) == nil
      assert Stdio.child_rss_mb(%{port: nil, pgid: nil}) == nil
    end
  end
end
