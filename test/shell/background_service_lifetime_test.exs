defmodule OptimalSystemAgent.Shell.BackgroundServiceLifetimeTest do
  @moduledoc """
  Species 3 of `docs/research/failure-taxonomy.md`: a service that was complete,
  verified live, and reported honestly — and dead by the time the grader
  arrived. `kv-store-grpc`, `pypi-server`, `configure-git-webserver`.

  ## The root cause, established here rather than assumed

  Three mechanisms could kill it and the taxonomy did not distinguish them: the
  BEAM `Port` closing with the VM, the container's process tree, or an explicit
  cleanup step. It is the cleanup step, and it is deliberate:
  `Agent.Loop.fire_session_end/2` calls
  `Shell.BackgroundManager.kill_for_session/1` ("WS6 — orphan reaping: a dying
  session must not leave its background shell commands running with nobody left
  to notify"), which reaps the whole process GROUP via `setsid`. That is correct
  for a build and fatal when the running service IS the deliverable — and the
  `shell_execute` prompt used to steer servers straight into it ("Pass
  `run_in_background: true` up front for builds, full suites **and servers**").

  The first test measures that reaping. The second measures the escape the
  prompt now names instead — daemonising out of the session — and is the reason
  the fix is guidance rather than a change to the reaping: reaping is what stops
  a normal session end from leaking processes, and it must keep doing that.

  Real processes, real signals; no provider involved.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Shell.BackgroundManager
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler, as: Shell

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    sid = "svc-life-#{System.unique_integer([:positive])}"
    {:ok, session_id: sid, dir: dir, pidfile: Path.join(dir, "svc.pid")}
  end

  # `kill -0` is the portable "is this pid alive" probe.
  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))

  defp await_pidfile(path, tries \\ 100)

  defp await_pidfile(path, 0), do: flunk("pidfile #{path} never appeared")

  defp await_pidfile(path, tries) do
    case File.read(path) do
      {:ok, raw} ->
        case raw |> String.trim() |> Integer.parse() do
          {pid, _} -> pid
          :error -> retry_pidfile(path, tries)
        end

      _ ->
        retry_pidfile(path, tries)
    end
  end

  defp retry_pidfile(path, tries) do
    Process.sleep(50)
    await_pidfile(path, tries - 1)
  end

  test "a run_in_background service is reaped when its session ends",
       %{session_id: sid, dir: dir, pidfile: pidfile} do
    {:ok, _id} =
      BackgroundManager.start("echo $$ > #{pidfile}; exec sleep 300", dir, session_id: sid)

    pid = await_pidfile(pidfile)
    assert alive?(pid), "the service should be up before the session ends"

    # Exactly what `Agent.Loop.fire_session_end/2` does on any session teardown.
    assert BackgroundManager.kill_for_session(sid) == 1

    # The group is signalled TERM then KILL; give the signal a moment to land.
    Process.sleep(300)

    refute alive?(pid),
           "the deliverable service outlived nothing: this is why the grader found a dead port"
  end

  test "a daemonised service survives the same teardown",
       %{session_id: sid, dir: dir, pidfile: pidfile} do
    # The incantation the `shell_execute` prompt now names for the case where
    # the task requires something still listening after the agent finishes.
    # `setsid` doesn't exist on macOS; `nohup ... &` is the same escape — the
    # child is reparented out of the session's process tree either way, which
    # is the property `kill_for_session/1` (a session-registry sweep) relies on.
    log = Path.join(dir, "svc.log")

    {:ok, _out} =
      Shell.execute(
        %{
          "command" =>
            "nohup sh -c 'echo $$ > #{pidfile}; exec sleep 300' " <>
              "</dev/null >#{log} 2>&1 &",
          "cwd" => dir
        },
        %{session_id: sid}
      )

    pid = await_pidfile(pidfile)
    assert alive?(pid)

    # It is not a BackgroundManager job at all, so session teardown has nothing
    # to reap — which is the whole point, and also why it must only be used
    # when the task actually calls for it.
    assert BackgroundManager.kill_for_session(sid) == 0
    Process.sleep(300)

    assert alive?(pid),
           "a daemonised service must outlive the session, or species 3 is not fixed"

    System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
  end

  test "the prompt no longer steers servers into the session-owned path" do
    prompt = OptimalSystemAgent.Tools.Builtins.ShellExecute.Prompt.render([])

    refute prompt =~ "full suites and servers"
    assert prompt =~ "setsid nohup"

    # The description names the distinction ("dies with the session") and the
    # escape hatch; the lifetime fact itself is a contract on the flag that
    # creates the doomed process, so it is stated on `run_in_background` — that
    # is where the model is deciding to set it. Both surfaces reach the model
    # in the same request; only one of them should carry the same sentence.
    assert prompt =~ "dies with the session"

    schema = Jason.encode!(OptimalSystemAgent.Tools.Builtins.ShellExecute.Tool.parameters())
    assert schema =~ "killed when the session ends"
  end
end
