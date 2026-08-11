defmodule OptimalSystemAgent.OS.ProcessGroupTest do
  @moduledoc """
  Tests for process-group reaping.

  SAFETY CONTRACT for everything in this file — this code sends signals to
  process GROUPS, and a mistake here does not fail a test, it kills the
  developer's desktop session:

    * every process signalled is spawned BY THIS TEST, under its own `setsid`,
      so it is a fresh session/group that contains nothing else;
    * the resolved pgid is asserted to be > 1, not the BEAM's own pgid, and to
      match the pgid of the specific child we spawned, BEFORE any signal;
    * no test ever signals pgid 0 (which means "my own group" to killpg), a
      negative literal, or a group it did not create.

  Do not relax any of those assertions.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OS.ProcessGroup

  @moduletag :tmp_dir

  # A tree exactly like the one a timed-out `npm run dev` leaves behind: a
  # wrapper shell whose real work is a DETACHED grandchild. Killing only the
  # wrapper leaves the grandchild orphaned.
  #
  # Prints "GC:<pid>" so the test knows precisely which pid to check, and never
  # has to guess or scan.
  @tree_script "sleep 300 & printf 'GC:%s\\n' \"$!\"; wait"

  defp setsid_available?, do: ProcessGroup.spawn_plan("/bin/sh", []).group?

  # Spawn one self-contained process tree under its own session. Returns
  # {port, wrapper_os_pid, grandchild_pid}.
  defp spawn_tree(cwd) do
    plan = ProcessGroup.spawn_plan(OptimalSystemAgent.OS.Shell.executable(), ["-c", @tree_script])

    port =
      Port.open(
        {:spawn_executable, plan.exe},
        [:binary, :exit_status, :hide, {:args, plan.args}, {:cd, cwd}]
      )

    {:os_pid, wrapper} = Port.info(port, :os_pid)
    {port, wrapper, await_grandchild(port, "")}
  end

  defp await_grandchild(port, acc) do
    receive do
      {^port, {:data, d}} ->
        acc = acc <> d

        case Regex.run(~r/GC:(\d+)/, acc) do
          [_, pid] -> String.to_integer(pid)
          nil -> await_grandchild(port, acc)
        end
    after
      10_000 -> flunk("child tree never reported its grandchild pid")
    end
  end

  # The safety gate. Called before ANY signal is sent.
  defp assert_safe_own_group!(pgid, grandchild) do
    own = ProcessGroup.own_pgid()

    assert is_integer(own) and own > 1,
           "cannot determine this BEAM's pgid — refusing to signal any group"

    assert is_integer(pgid), "pgid must resolve to an integer, got #{inspect(pgid)}"
    assert pgid > 1, "refusing pgid #{pgid}: 0 means our own group, 1 is init"
    assert pgid != own, "resolved pgid #{pgid} IS this BEAM's group — would kill the node"
    assert ProcessGroup.killpg_safe?(pgid)

    # The group must be the one holding the child we spawned, not some
    # unrelated group that happens to have that id.
    {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(grandchild)])

    assert String.trim(out) == to_string(pgid),
           "grandchild #{grandchild} is not in the group we are about to signal"
  end

  defp eventually(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> (Process.sleep(50) && do_eventually(fun, deadline))
    end
  end

  describe "killpg_safe?/1 — the guard that must never be removed" do
    test "refuses the ids that would take down the machine" do
      # 0 = "every process in the CALLER'S group" — i.e. the BEAM and whatever
      # shares its group, up to the login session.
      refute ProcessGroup.killpg_safe?(0)
      # 1 = init.
      refute ProcessGroup.killpg_safe?(1)
      refute ProcessGroup.killpg_safe?(-1)
      refute ProcessGroup.killpg_safe?(-9999)
    end

    test "refuses this node's own process group" do
      own = ProcessGroup.own_pgid()
      assert is_integer(own)
      refute ProcessGroup.killpg_safe?(own)
    end

    test "refuses non-integers rather than coercing them" do
      refute ProcessGroup.killpg_safe?(nil)
      refute ProcessGroup.killpg_safe?("1234")
      refute ProcessGroup.killpg_safe?(:all)
    end

    test "signal_group/2 returns an error instead of signalling an unsafe group" do
      assert ProcessGroup.signal_group(0, "TERM") == {:error, :unsafe_pgid}
      assert ProcessGroup.signal_group(1, "TERM") == {:error, :unsafe_pgid}
      assert ProcessGroup.signal_group(ProcessGroup.own_pgid(), "TERM") == {:error, :unsafe_pgid}
      assert ProcessGroup.terminate_group(0, 0) == {:error, :unsafe_pgid}
    end
  end

  describe "leader_pid/1" do
    test "returns nil rather than guessing when there is no wrapper" do
      assert ProcessGroup.leader_pid(nil) == nil
    end
  end

  describe "spawn_plan/2" do
    test "wraps in setsid -w when available so the child leads its own group" do
      plan = ProcessGroup.spawn_plan("/bin/echo", ["hi"])

      if setsid_available?() do
        assert plan.group?
        assert String.ends_with?(plan.exe, "setsid")
        assert plan.args == ["-w", "/bin/echo", "hi"]
      else
        refute plan.group?
        assert plan.exe == "/bin/echo"
      end
    end
  end

  # Compile-time gate: on a host with no `setsid` there is no process group to
  # reap and these tests are meaningless rather than failing.
  if System.find_executable("setsid") do
  describe "reaping a process tree" do
    # The pid handed to BackgroundManager on adoption must be the COMMAND, not
    # the setsid wrapper — BackgroundManager kills a single pid, and killing the
    # wrapper would leave the command running.
    test "leader_pid/1 returns the command, not the setsid wrapper", %{tmp_dir: tmp} do
      {port, wrapper, grandchild} = spawn_tree(tmp)
      leader = ProcessGroup.leader_pid(wrapper)
      pgid = ProcessGroup.resolve_pgid(wrapper)

      try do
        assert is_integer(leader)
        assert leader != wrapper
        # The group leader's pid IS the pgid, by definition of setsid.
        assert leader == pgid
        assert ProcessGroup.pid_alive?(leader)
      after
        assert_safe_own_group!(pgid, grandchild)
        _ = ProcessGroup.terminate_group(pgid, 500)
        _ = safe_close(port)
      end
    end

    test "resolves the child's own group, never the BEAM's", %{tmp_dir: tmp} do
      {port, wrapper, grandchild} = spawn_tree(tmp)
      pgid = ProcessGroup.resolve_pgid(wrapper)

      try do
        assert_safe_own_group!(pgid, grandchild)
      after
        _ = ProcessGroup.terminate_group(pgid, 500)
        _ = safe_close(port)
      end
    end

    # THE regression. On the original code `kill_os_process/1` sent
    # `kill -TERM <wrapper>` then `kill -KILL <wrapper>` — one pid, no group —
    # and this grandchild survived, holding whatever ports and file handles it
    # had open. This test asserts it dies.
    test "terminate_group/2 kills the detached grandchild too", %{tmp_dir: tmp} do
      {port, wrapper, grandchild} = spawn_tree(tmp)
      pgid = ProcessGroup.resolve_pgid(wrapper)
      assert_safe_own_group!(pgid, grandchild)

      assert ProcessGroup.pid_alive?(grandchild)
      assert ProcessGroup.terminate_group(pgid, 500) == :ok

      assert eventually(fn -> not ProcessGroup.pid_alive?(grandchild) end),
             "grandchild #{grandchild} survived the group kill — still orphaned"

      safe_close(port)
    end

    # Characterizes the OLD behavior so the difference is not a matter of
    # opinion: killing the single wrapper pid leaves the tree running. The
    # orphan is cleaned up by the group kill at the end of the test.
    test "killing only the wrapper pid leaves the grandchild orphaned", %{tmp_dir: tmp} do
      {port, wrapper, grandchild} = spawn_tree(tmp)
      pgid = ProcessGroup.resolve_pgid(wrapper)
      assert_safe_own_group!(pgid, grandchild)

      ProcessGroup.terminate_pid(wrapper, 200)

      assert ProcessGroup.pid_alive?(grandchild),
             "expected the single-pid kill to orphan the grandchild"

      # Clean up the orphan we just demonstrated, via the guarded group path.
      _ = ProcessGroup.terminate_group(pgid, 500)
      assert eventually(fn -> not ProcessGroup.pid_alive?(grandchild) end)
      safe_close(port)
    end

    # TERM and KILL used to be sent back to back, so a cleanup handler could
    # never run — the TERM was functionally a KILL. Here the child TRAPS
    # SIGTERM and writes a marker; the marker only exists if the TERM arrived
    # and the process was given time to act on it before the KILL.
    test "SIGTERM is delivered with a grace window, not merged into the KILL",
         %{tmp_dir: tmp} do
      marker = Path.join(tmp, "termed")

      script = """
      trap 'printf caught > #{marker}; exit 0' TERM
      sleep 300 &
      printf 'GC:%s\\n' "$!"
      wait
      """

      plan = ProcessGroup.spawn_plan(OptimalSystemAgent.OS.Shell.executable(), ["-c", script])

      port =
        Port.open(
          {:spawn_executable, plan.exe},
          [:binary, :exit_status, :hide, {:args, plan.args}, {:cd, tmp}]
        )

      {:os_pid, wrapper} = Port.info(port, :os_pid)
      grandchild = await_grandchild(port, "")

      pgid = ProcessGroup.resolve_pgid(wrapper)
      assert_safe_own_group!(pgid, grandchild)

      assert ProcessGroup.terminate_group(pgid, 2_000) == :ok

      assert eventually(fn -> File.exists?(marker) end),
             "the SIGTERM handler never ran — TERM and KILL were not separated"

      assert eventually(fn -> not ProcessGroup.pid_alive?(grandchild) end)
      safe_close(port)
    end
  end
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
