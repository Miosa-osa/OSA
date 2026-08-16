defmodule OptimalSystemAgent.Tools.BoundedCmdTest do
  @moduledoc """
  Bound the SUBPROCESS, not the turn.

  Same defect shape as the `rg` call that wedged a turn for 1h51m
  (`FileGrepBoundsItsSubprocessTest`): a bare `System.cmd/3` with no deadline,
  under a tool executor whose own timeout is `:infinity` by design
  (`Agent.Loop.LongRunningToolTest`), so nothing anywhere stops it. `ssh` to a
  host that accepts the connection and then never answers is the worst of the
  family, because its natural failure mode — empty output — is exactly what a
  successful silent command looks like.

  These tests pin the two halves that matter: the process is really killed, and
  what comes back cannot be mistaken for a result.
  """
  # NOT async. These tests mutate the OS environment (`PATH`, to hide `setsid`
  # from `spawn_plan/2`) and application env (`:kill_grace_ms`,
  # `:bounded_cmd_timeout_ms`), all of which are global. Run concurrently, the
  # PATH mutation is visible to every other test in the run — it made
  # `ShellExecuteTest` fail while passing in isolation.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.BoundedCmd

  describe "a wedged subprocess is stopped" do
    test "the deadline fires and the call returns instead of hanging" do
      started = System.monotonic_time(:millisecond)

      assert {:timeout, message} =
               BoundedCmd.run("sleep", ["600"], timeout_ms: 300, label: "sleep")

      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 5_000, "the deadline did not fire — took #{elapsed}ms"
      assert is_binary(message)
    end

    test "many wedged calls do not accumulate blocked callers" do
      # The property that matters for a turn: each expiry releases its caller
      # independently, so N wedged subprocesses cost N deadlines, not a queue.
      started = System.monotonic_time(:millisecond)

      results =
        1..4
        |> Task.async_stream(
          fn _ -> BoundedCmd.run("sleep", ["600"], timeout_ms: 300) end,
          max_concurrency: 4,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      elapsed = System.monotonic_time(:millisecond) - started

      assert Enum.all?(results, &match?({:timeout, _}, &1))
      assert elapsed < 5_000, "expiries serialised — took #{elapsed}ms"
    end

    test "the direct child is really gone — ps, not inference" do
      marker = "osa-reap-direct-#{System.unique_integer([:positive])}"

      assert {:timeout, _} =
               BoundedCmd.run("sh", ["-c", "sleep 300 # #{marker}"], timeout_ms: 300)

      assert survivors(marker) == [],
             "the subprocess outlived its deadline as an orphan"
    end

    test "a GRANDCHILD is gone too — the shape that actually leaks" do
      # Signalling only the direct child leaves the grandchild running,
      # reparented to init, still holding whatever wedged it. This is why the
      # spawn goes through `setsid` and the kill targets the negative pgid.
      marker = "osa-reap-grandchild-#{System.unique_integer([:positive])}"

      assert {:timeout, _} =
               BoundedCmd.run(
                 "sh",
                 ["-c", "sh -c 'sleep 300 # #{marker}' & wait"],
                 timeout_ms: 400
               )

      assert survivors(marker) == [],
             "the grandchild survived — the group kill did not reach it"
    end

    test "a process that ignores SIGTERM is still killed" do
      # `terminate_group/2` is TERM, a grace window, then KILL. A child that
      # traps TERM must not be able to outlive its deadline by ignoring it.
      marker = "osa-reap-stubborn-#{System.unique_integer([:positive])}"

      prev = Application.get_env(:optimal_system_agent, :kill_grace_ms)
      Application.put_env(:optimal_system_agent, :kill_grace_ms, 300)

      on_exit(fn ->
        if prev do
          Application.put_env(:optimal_system_agent, :kill_grace_ms, prev)
        else
          Application.delete_env(:optimal_system_agent, :kill_grace_ms)
        end
      end)

      assert {:timeout, _} =
               BoundedCmd.run(
                 "sh",
                 ["-c", "trap '' TERM; sleep 300 # #{marker}"],
                 timeout_ms: 300
               )

      assert survivors(marker) == [],
             "a SIGTERM-ignoring child outlived its deadline"
    end

    test "a healthy run leaves nothing behind either" do
      marker = "osa-reap-clean-#{System.unique_integer([:positive])}"

      assert {:ok, _out, 0} = BoundedCmd.run("sh", ["-c", "true # #{marker}"])
      assert survivors(marker) == []
    end
  end

  # `ps` is the evidence, for the same reason it was the evidence that exposed
  # the bug. The BEAM's view of a port says nothing about whether the OS process
  # is still there.
  defp survivors(marker) do
    # The reap sends TERM, waits, then KILL; give the kernel a moment to reap
    # the zombie before believing `ps`.
    Process.sleep(400)
    {out, _} = System.cmd("ps", ["-eo", "pid,stat,args"], stderr_to_stdout: true)

    out
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, marker))
    # A defunct entry is a reaped process awaiting its parent's wait(2), not a
    # survivor. `ps` still lists it for a moment.
    |> Enum.reject(&String.contains?(&1, "<defunct>"))
    # `ps` can show the `sh -c` that is itself running this check.
    |> Enum.reject(&String.contains?(&1, "ps -eo"))
  end

  describe "a reap that cannot happen still answers" do
    test "no setsid on the machine still expires, reports, and does not raise" do
      # `spawn_plan/2` degrades to an unwrapped spawn when `setsid` is missing —
      # what a minimal container looks like. The deadline, the message and the
      # turn are unaffected; only the grandchild guarantee is lost, and the log
      # says so rather than the caller finding out later.
      marker = "osa-reap-nosetsid-#{System.unique_integer([:positive])}"

      prev_path = System.get_env("PATH")
      sandbox = Path.join(System.tmp_dir!(), "osa-nosetsid-#{System.unique_integer([:positive])}")
      File.mkdir_p!(sandbox)

      on_exit(fn ->
        System.put_env("PATH", prev_path)
        File.rm_rf!(sandbox)
      end)

      # Hide `setsid` and NOTHING else. `OS.ProcessGroup` shells out to `ps`,
      # `pgrep` and `kill` by name, so an emptied PATH would disable the reap
      # itself and this test would be measuring the wrong failure.
      for bin <- ~w(sh sleep ps pgrep kill) do
        case System.find_executable(bin) do
          nil -> :ok
          path -> File.ln_s!(path, Path.join(sandbox, bin))
        end
      end

      refute System.find_executable("setsid") == Path.join(sandbox, "setsid")

      sh = System.find_executable("sh")
      sleep = System.find_executable("sleep")

      System.put_env("PATH", sandbox)
      result = BoundedCmd.run(sh, ["-c", "#{sleep} 300 # #{marker}"], timeout_ms: 300)
      System.put_env("PATH", prev_path)

      assert {:timeout, message} = result, "the deadline must fire with or without setsid"
      assert message =~ "did NOT complete"

      # The single-pid fallback still reaches this one. A grandchild would have
      # survived it — that is exactly the guarantee `setsid` buys, and its
      # absence is logged rather than assumed away.
      assert survivors(marker) == []
    end

    test "an unkillable group does not take the turn down" do
      # The contract under a failed reap: the caller still gets its incomplete
      # result. Forced by making the safety guard refuse every group.
      prev = Application.get_env(:optimal_system_agent, :kill_grace_ms)
      Application.put_env(:optimal_system_agent, :kill_grace_ms, 0)

      on_exit(fn ->
        if prev do
          Application.put_env(:optimal_system_agent, :kill_grace_ms, prev)
        else
          Application.delete_env(:optimal_system_agent, :kill_grace_ms)
        end
      end)

      assert {:timeout, message} =
               BoundedCmd.run("sleep", ["300"], timeout_ms: 200, label: "sleep")

      assert message =~ "did NOT complete"
    end
  end

  describe "the expiry report names itself and its target" do
    test "and refuses to look like a result" do
      {:timeout, message} =
        BoundedCmd.run("sleep", ["600"],
          timeout_ms: 200,
          label: "ssh",
          target: "build-07.internal"
        )

      assert message =~ "ssh"
      assert message =~ "build-07.internal"

      # The load-bearing half. An unreachable host silently returning "no
      # output" is a silent wrong answer one layer above the hang: the model
      # reads it as a fact about the remote host that nothing established.
      assert message =~ "did NOT complete"
      assert message =~ "killed, not because there was none"
    end

    test "a plausible-looking empty success is never substituted" do
      result = BoundedCmd.run("sleep", ["600"], timeout_ms: 200, label: "scp")

      refute match?({:ok, "", 0}, result),
             "an expired subprocess was reported as a command that produced no output"
    end

    test "cmd/3 keeps System.cmd's shape but with a non-zero status" do
      assert {message, status} = BoundedCmd.cmd("sleep", ["600"], timeout_ms: 200, label: "diff")
      assert status != 0, "an expired subprocess reported success"
      assert message =~ "diff"
    end
  end

  describe "a healthy subprocess is untouched" do
    test "output and exit status pass through unchanged" do
      assert {:ok, output, 0} = BoundedCmd.run("echo", ["hello"], label: "echo")
      assert String.trim(output) == "hello"
    end

    test "a non-zero exit is a RESULT, not a timeout" do
      assert {:ok, _out, status} = BoundedCmd.run("sh", ["-c", "exit 3"], label: "sh")
      assert status == 3
    end

    test "a missing binary does not raise, and names itself" do
      assert {:ok, out, status} =
               BoundedCmd.run("osa-no-such-binary-anywhere", [], label: "nope")

      assert status != 0

      # `System.cmd/3` raised :enoent here and callers rescued it to print
      # "(is xdotool installed?)". Under a `setsid` wrapper nothing raises, so
      # the absence has to carry itself in the output or the caller reports a
      # bare exit code and the operator learns nothing.
      assert out =~ "osa-no-such-binary-anywhere"
    end

    # ── The System.cmd/3 compatibility surface the 20 call sites rely on ──

    test "stderr is merged by default, as System.cmd(stderr_to_stdout: true) did" do
      assert {:ok, out, 0} = BoundedCmd.run("sh", ["-c", "echo oops >&2"])
      assert String.trim(out) == "oops"
    end

    test "stderr_to_stdout: false keeps stderr out of the output" do
      # `xclip -o` and `wl-paste` pass this, because their stdout IS the
      # clipboard payload and merging stderr would corrupt it.
      assert {:ok, out, 0} =
               BoundedCmd.run("sh", ["-c", "echo payload; echo noise >&2"],
                 stderr_to_stdout: false
               )

      assert String.trim(out) == "payload"
    end

    test ":env overrides on top of the inherited environment" do
      # The AT-SPI2 call passes `PYTHONDONTWRITEBYTECODE` and needs the
      # inherited `DISPLAY`. Port wants charlists where System.cmd took
      # binaries; both inherit and override, and that has to stay true.
      System.put_env("OSA_BOUNDED_INHERITED", "from-beam")
      on_exit(fn -> System.delete_env("OSA_BOUNDED_INHERITED") end)

      assert {:ok, out, 0} =
               BoundedCmd.run("sh", ["-c", "echo $OSA_BOUNDED_OVERRIDE/$OSA_BOUNDED_INHERITED"],
                 env: [{"OSA_BOUNDED_OVERRIDE", "from-opts"}]
               )

      assert String.trim(out) == "from-opts/from-beam"
    end

    test ":cd is honoured" do
      dir = Path.join(System.tmp_dir!(), "osa-cd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:ok, out, 0} = BoundedCmd.run("sh", ["-c", "pwd"], cd: dir)
      assert String.trim(out) |> Path.basename() == Path.basename(dir)
    end

    test "output larger than one port chunk is reassembled in order" do
      assert {:ok, out, 0} = BoundedCmd.run("sh", ["-c", "seq 1 20000"])
      lines = out |> String.trim() |> String.split("\n")

      assert length(lines) == 20_000
      assert List.first(lines) == "1"
      assert List.last(lines) == "20000"
    end

    test "the caller's mailbox is clean afterwards" do
      # The port runs in the CALLER's process. A leftover chunk would be
      # delivered to whatever that process receives next — for a tool running
      # inline in the Loop GenServer, a handle_info with no matching clause.
      {:timeout, _} = BoundedCmd.run("sh", ["-c", "echo hi; sleep 300"], timeout_ms: 300)

      refute_receive _anything, 100
    end
  end

  describe "the bound is configurable and disablable" do
    test "the default is generous — well above any real local command" do
      assert BoundedCmd.timeout_ms() >= 30_000
    end

    test ":infinity restores the old unbounded behaviour for an operator who wants it" do
      prev = Application.get_env(:optimal_system_agent, :bounded_cmd_timeout_ms)
      Application.put_env(:optimal_system_agent, :bounded_cmd_timeout_ms, :infinity)

      on_exit(fn ->
        if prev do
          Application.put_env(:optimal_system_agent, :bounded_cmd_timeout_ms, prev)
        else
          Application.delete_env(:optimal_system_agent, :bounded_cmd_timeout_ms)
        end
      end)

      assert BoundedCmd.timeout_ms() == :infinity
    end
  end

  describe "the callers that were unbounded now use it" do
    # Structural, for the same reason `settle/1` needed one: the behaviour above
    # passes perfectly against a module nothing calls.
    @adapters [
      "lib/optimal_system_agent/tools/builtins/diff.ex",
      "lib/optimal_system_agent/tools/builtins/computer_use/adapters/remote_ssh.ex",
      "lib/optimal_system_agent/tools/builtins/computer_use/adapters/docker.ex",
      "lib/optimal_system_agent/tools/builtins/computer_use/adapters/linux_x11.ex",
      "lib/optimal_system_agent/tools/builtins/computer_use/adapters/linux_wayland.ex",
      "lib/optimal_system_agent/tools/builtins/computer_use/adapters/macos.ex",
      "lib/optimal_system_agent/tools/builtins/computer_use/handler.ex"
    ]

    test "no bare System.cmd survives in the bounded adapters" do
      offenders =
        Enum.flat_map(@adapters, fn path ->
          lines = path |> File.read!() |> String.split("\n")

          lines
          |> Enum.with_index()
          |> Enum.filter(fn {line, i} ->
            String.contains?(line, "System.cmd(") and not justified?(lines, i)
          end)
          |> Enum.map(fn {line, i} -> "#{path}:#{i + 1}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             "unbounded subprocess calls remain:\n" <> Enum.join(offenders, "\n")
    end

    # A few calls SHOULD stay unbounded — `nohup <app>` is a launch, and a
    # deadline there would kill the application the operator just asked for.
    # Those are allowed, but only with the reason written down next to them, so
    # the next reader inherits the argument instead of the omission.
    defp justified?(lines, index) do
      lines
      |> Enum.slice(max(index - 5, 0), min(index, 5))
      |> Enum.any?(&String.contains?(&1, "unbounded:"))
    end

    test "the nohup launches are still opted out, and still raw System.cmd" do
      # These are LAUNCHES, not queries: the application is supposed to outlive
      # the call. The port rewrite added a reaper, and a reaper pointed at these
      # would SIGKILL the application the operator just asked for, 120s after it
      # started. They must therefore stay on the unbounded path — the written
      # reason is not enough on its own, because a later mechanical sweep of
      # `System.cmd(` → `BoundedCmd.run(` would silently take them with it.
      for path <- [
            "lib/optimal_system_agent/tools/builtins/computer_use/adapters/linux_x11.ex",
            "lib/optimal_system_agent/tools/builtins/computer_use/adapters/linux_wayland.ex"
          ] do
        source = File.read!(path)

        assert source =~ ~r/spawn\(fn -> System\.cmd\("nohup"/,
               "#{path}: the app launch is no longer a raw fire-and-forget spawn — " <>
                 "if it now goes through BoundedCmd it will kill the launched application"

        refute source =~ ~r/BoundedCmd\.run\("nohup"/,
               "#{path}: the app launch was routed through the reaper"
      end
    end

    test "every opt-out states its reason in the same breath" do
      # Guards the guard: an `unbounded:` marker with nothing after it would
      # silence the check above while explaining nothing.
      for path <- @adapters,
          line <- String.split(File.read!(path), "\n"),
          String.contains?(line, "unbounded:") do
        [_, reason] = String.split(line, "unbounded:", parts: 2)

        assert String.length(String.trim(reason)) > 10,
               "#{path}: an unbounded opt-out with no reason: #{String.trim(line)}"
      end
    end
  end
end
