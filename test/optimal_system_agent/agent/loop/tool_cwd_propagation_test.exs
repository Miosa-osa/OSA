defmodule OptimalSystemAgent.Agent.Loop.ToolCwdPropagationTest do
  @moduledoc """
  A tool must run in the SESSION's working directory, not the backend's.

  `Workspace.Cwd.get/0` reads the process dictionary, and a process dictionary
  does NOT propagate to a spawned Task. Every tool runs in one — both
  `ToolOrchestrator` and `StreamingToolExecutor` use
  `Task.Supervisor.async_nolink` — so `shell_execute`, which defaults to
  `Cwd.get/0`, fell through to `original_cwd()`: the directory the *backend*
  booted in.

  Observed in a SWE-bench Pro run: `pwd` returned the backend's boot directory,
  so `git log` read OSA's own history rather than the task repository's. It
  showed in only 4 of 12 instances because a command carrying an explicit `cwd`,
  or starting with its own `cd`, never consults the default.

  On a shared daemon serving several sessions this is worse than a benchmark
  artefact — it is one session's tool running in another session's directory.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Workspace.Cwd

  @tag :tmp_dir
  test "a Task does not inherit the caller's cwd override", %{tmp_dir: tmp} do
    # The mechanism itself, pinned. If this ever starts passing without the
    # explicit re-publish below, the platform changed and the fix can go.
    Cwd.put_process_override(tmp)
    assert Cwd.get() == tmp

    inherited =
      Task.async(fn -> Cwd.get() end)
      |> Task.await()

    refute inherited == tmp,
           "process dictionaries suddenly propagate to Tasks — re-check the fix"
  end

  @tag :tmp_dir
  test "re-publishing inside the Task restores the session's directory", %{tmp_dir: tmp} do
    # This is exactly what ToolOrchestrator and StreamingToolExecutor now do:
    # read on the caller, which holds the override, and re-publish in the Task.
    Cwd.put_process_override(tmp)
    caller_cwd = Cwd.get()

    seen =
      Task.async(fn ->
        Cwd.put_process_override(caller_cwd)
        Cwd.get()
      end)
      |> Task.await()

    assert seen == tmp, "tool would have run in #{seen} instead of the session directory"
  end

  test "both spawn sites capture the cwd before spawning" do
    # A source assertion, deliberately. The behavioural tests above prove the
    # mechanism but cannot prove the call sites use it, and the failure is
    # silent: a tool in the wrong directory still succeeds, it just operates on
    # the wrong files.
    for path <- [
          "lib/optimal_system_agent/agent/loop/tool_orchestrator.ex",
          "lib/optimal_system_agent/agent/loop/streaming_tool_executor.ex"
        ] do
      src = File.read!(path)

      assert src =~ "caller_cwd = OptimalSystemAgent.Workspace.Cwd.get()",
             "#{path} does not capture the caller's cwd before spawning"

      assert src =~ "Workspace.Cwd.put_process_override(caller_cwd)",
             "#{path} does not re-publish the cwd inside the Task"
    end
  end
end
