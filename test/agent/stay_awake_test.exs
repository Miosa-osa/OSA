defmodule OptimalSystemAgent.Agent.StayAwakeTest do
  @moduledoc """
  The daemon must hold the machine awake while a turn runs.

  The TUI has its own inhibitor, but the TUI is not what does the work: OSA runs
  as a background daemon that outlives any attached terminal. Without a
  backend-side hold, an unattended overnight run dies when the machine idles
  out — silently, mid-turn, looking exactly like the agent stopping for no
  reason.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.StayAwake

  # A harmless stand-in for `caffeinate`: spawns, stays alive, kills cleanly.
  defp fake_inhibitor, do: {System.find_executable("sleep"), ["30"]}

  setup do
    previous = Application.get_env(:optimal_system_agent, :stay_awake_command)
    Application.put_env(:optimal_system_agent, :stay_awake_command, fake_inhibitor())

    name = :"stay_awake_#{System.unique_integer([:positive])}"
    {:ok, pid} = StayAwake.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)

      case previous do
        nil -> Application.delete_env(:optimal_system_agent, :stay_awake_command)
        v -> Application.put_env(:optimal_system_agent, :stay_awake_command, v)
      end
    end)

    {:ok, server: pid, name: name}
  end

  defp acquire(name, session, pid \\ self()) do
    GenServer.cast(name, {:acquire, session, pid})
    :sys.get_state(name)
  end

  defp release(name, session) do
    GenServer.cast(name, {:release, session})
    :sys.get_state(name)
  end

  describe "holding the machine awake" do
    test "a turn starts the inhibitor and ending it releases", %{name: name} do
      assert %{port: nil} = :sys.get_state(name)

      assert %{port: port} = acquire(name, "s1")
      assert is_port(port), "no inhibitor started for an active turn"

      assert %{port: nil} = release(name, "s1")
    end

    test "concurrent sessions do not release each other's hold", %{name: name} do
      # The failure this pins: two overnight sessions, the shorter one finishes,
      # and the machine sleeps out from under the one still working.
      acquire(name, "s1")
      %{port: port} = acquire(name, "s2")
      assert is_port(port)

      assert %{port: ^port} = release(name, "s1")
      assert %{port: nil} = release(name, "s2")
    end

    test "acquiring twice for one session still needs only one release", %{name: name} do
      acquire(name, "s1")
      acquire(name, "s1")

      assert %{port: nil} = release(name, "s1"),
             "a duplicate acquire left a hold that outlived its release"
    end

    test "releasing something never acquired is harmless", %{name: name} do
      assert %{port: nil} = release(name, "never-seen")
    end
  end

  describe "it cannot pin the machine awake forever" do
    test "a crashed holder releases its hold", %{name: name} do
      # Without monitoring, a loop process that dies mid-turn would leave
      # `caffeinate` running until reboot — worse than having no inhibitor.
      holder = spawn(fn -> Process.sleep(:infinity) end)

      %{port: port} = acquire(name, "s1", holder)
      assert is_port(port)

      Process.exit(holder, :kill)
      # Let the DOWN message land.
      Process.sleep(50)

      assert %{port: nil} = :sys.get_state(name),
             "a dead holder kept the machine awake"
    end

    test "stopping the server releases the inhibitor", %{name: name} do
      %{port: port} = acquire(name, "s1")
      os_pid = port |> Port.info(:os_pid) |> elem(1)

      GenServer.stop(name, :normal)
      Process.sleep(50)

      {out, _} = System.cmd("ps", ["-p", to_string(os_pid)], stderr_to_stdout: true)
      refute out =~ to_string(os_pid), "inhibitor survived server shutdown: #{out}"
    end
  end

  describe "platforms without an inhibitor" do
    test "a turn still proceeds when none is available", %{name: name} do
      Application.put_env(:optimal_system_agent, :stay_awake_command, :disabled)

      # No port, no crash, no error — an unprotected turn beats a failed one.
      assert %{port: nil} = acquire(name, "s1")
      assert %{port: nil} = release(name, "s1")
    end

    test "the public API never raises when the server is not running" do
      # The loop calls these on every turn; they must not be able to fail it.
      assert :ok = StayAwake.acquire("no-server-running")
      assert :ok = StayAwake.release("no-server-running")
      refute StayAwake.held?()
    end
  end
end
