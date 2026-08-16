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
  use ExUnit.Case, async: true

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

    @tag :orphan_reaping
    test "MEASURED: the OS process is NOT reaped — see the moduledoc" do
      # Pinned as a known limitation rather than left as folklore. `file_grep`'s
      # comment claims closing the Port kills the child; it does not. If this
      # test ever fails, the platform (or a move to `Port.open/2` +
      # `OS.ProcessGroup`) has fixed it and both moduledocs should be corrected.
      marker = "osa-bounded-cmd-#{System.unique_integer([:positive])}"

      assert {:timeout, _} =
               BoundedCmd.run("sh", ["-c", "sleep 30 # #{marker}"], timeout_ms: 300)

      Process.sleep(400)
      {out, _} = System.cmd("ps", ["-eo", "pid,args"], stderr_to_stdout: true)

      survivors =
        out
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, marker))

      assert survivors != [],
             "the child was reaped after all — update BoundedCmd's and file_grep's moduledocs"

      # Do not leave the probe running for 30s.
      Enum.each(survivors, fn line ->
        case Integer.parse(String.trim(line)) do
          {pid, _} -> System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
          _ -> :ok
        end
      end)
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

    test "a missing binary does not raise out of the wrapper" do
      assert {:ok, _out, status} =
               BoundedCmd.run("osa-no-such-binary-anywhere", [], label: "nope")

      assert status != 0
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
