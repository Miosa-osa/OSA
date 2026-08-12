defmodule OptimalSystemAgent.Shell.BackgroundTaskProcessGroupTest do
  @moduledoc """
  Killing a background task must reap the WHOLE process tree, not just the
  shell at the top of it.

  Regression: `do_kill/1` sent `kill -TERM <pid>` immediately followed by
  `kill -KILL <pid>` against a single pid with no process group, so a
  backgrounded `npm run dev` / `docker run` / dev server kept running after the
  task reported `:killed` — still holding its ports and file handles. The
  identical defect was already fixed for foreground `shell_execute`.

  ## Test safety

  This runs on a real desktop, so the rules are strict and enforced in the test
  itself, not assumed:

    * the only processes involved are ones this test spawned, via
      `BackgroundManager`, which spawns under `setsid` — a FRESH session;
    * before allowing the kill, the test asserts the group it created is
      neither the BEAM's own group nor pgid <= 1;
    * the test never signals a group itself. It signals nothing but the single
      descendant pid it created, and only in cleanup.

  No `pkill`, no `killall`, no pgid 0.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OS.ProcessGroup
  alias OptimalSystemAgent.Shell.BackgroundManager

  @moduletag :tmp_dir

  setup do
    if match?({:win32, _}, :os.type()) or System.find_executable("setsid") == nil do
      {:ok, skip: true}
    else
      {:ok, skip: false}
    end
  end

  test "killing a background task also kills the process it spawned", ctx do
    if ctx.skip do
      :ok
    else
      pid_file = Path.join(ctx.tmp_dir, "descendant.pid")

      # The shell backgrounds a long sleep, records its pid, then waits. Killing
      # only the shell leaves that sleep alive — which is exactly the bug.
      command = "sleep 300 & echo $! > #{pid_file}; wait"

      {:ok, id} = BackgroundManager.start(command, ctx.tmp_dir)

      descendant = await_pid(pid_file)
      assert ProcessGroup.pid_alive?(descendant), "descendant never started"

      on_exit(fn ->
        # Cleanup targets ONE pid — the one this test created — never a group.
        if ProcessGroup.pid_alive?(descendant), do: ProcessGroup.terminate_pid(descendant, 500)
      end)

      # ── Safety gate ──────────────────────────────────────────────────
      # Prove the group about to be reaped is one we created and not ours.
      group = ProcessGroup.pgid_of(descendant)
      assert is_integer(group) and group > 1, "could not resolve the descendant's group"

      own = ProcessGroup.own_pgid()
      assert is_integer(own), "could not read this node's own group"
      refute group == own, "descendant shares the BEAM's process group — refusing to proceed"
      assert ProcessGroup.killpg_safe?(group)

      BackgroundManager.kill(id)

      assert wait_until(10_000, fn -> not ProcessGroup.pid_alive?(descendant) end),
             "descendant #{descendant} survived the kill — the process tree was orphaned"
    end
  end

  defp await_pid(path) do
    if wait_until(10_000, fn -> File.exists?(path) and String.trim(File.read!(path)) != "" end) do
      case path |> File.read!() |> String.trim() |> Integer.parse() do
        {pid, _} when pid > 1 -> pid
        _ -> flunk("unreadable descendant pid in #{path}")
      end
    else
      flunk("descendant pid file never appeared at #{path}")
    end
  end

  defp wait_until(budget_ms, _fun) when budget_ms <= 0, do: false

  defp wait_until(budget_ms, fun) do
    if fun.() do
      true
    else
      Process.sleep(100)
      wait_until(budget_ms - 100, fun)
    end
  end
end
