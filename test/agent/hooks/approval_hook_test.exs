defmodule OptimalSystemAgent.Agent.Hooks.ApprovalHookTest do
  @moduledoc """
  `OSA_PRE_TOOL_HOOK`: the external approval gate, run as a real shell command.

  Covers the protocol (exit 0 allows, exit 2 denies with the stdout reason,
  Claude Code JSON decisions), fail-closed behaviour, the hook input, and the
  routing in `ToolExecutor`: an unattended approval goes to the hook when one
  covers the tool, and fails closed otherwise.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks.ApprovalHook
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.{Attendance, PermissionMode}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> ApprovalHook.unregister() end)
    {:ok, dir: dir}
  end

  defp script(dir, body) do
    path = Path.join(dir, "hook-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    "/bin/sh " <> path
  end

  defp config(command, opts \\ []) do
    %{
      command: command,
      timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
      matcher: Keyword.get(opts, :matcher)
    }
  end

  defp payload(extra \\ %{}) do
    Map.merge(
      %{
        tool_name: "shell_execute",
        arguments: %{"command" => "git push"},
        session_id: "s-approval",
        tool_use_id: "call_42",
        working_dir: "/workspace",
        permission_mode: "default"
      },
      extra
    )
  end

  describe "configuration" do
    test "from the environment" do
      assert ApprovalHook.config(%{}) == nil
      assert ApprovalHook.config(%{"OSA_PRE_TOOL_HOOK" => "  "}) == nil

      assert ApprovalHook.config(%{
               "OSA_PRE_TOOL_HOOK" => "/bin/sh gate.sh",
               "OSA_PRE_TOOL_HOOK_TIMEOUT" => "30",
               "OSA_PRE_TOOL_HOOK_MATCHER" => "shell_execute|mcp__.*"
             }) == %{
               command: "/bin/sh gate.sh",
               timeout_ms: 30_000,
               matcher: "shell_execute|mcp__.*"
             }

      assert %{timeout_ms: 86_400_000, matcher: nil} =
               ApprovalHook.config(%{
                 "OSA_PRE_TOOL_HOOK" => "x",
                 "OSA_PRE_TOOL_HOOK_TIMEOUT" => "soon"
               })
    end

    test "covers? follows the matcher, and nothing is covered without a hook" do
      refute ApprovalHook.covers?("shell_execute")

      ApprovalHook.register(config("true", matcher: "shell_execute|mcp__.*"))
      assert ApprovalHook.active?()
      assert ApprovalHook.covers?("shell_execute")
      assert ApprovalHook.covers?("mcp__github__create_issue")
      refute ApprovalHook.covers?("file_read")

      ApprovalHook.unregister()
      refute ApprovalHook.active?()
    end
  end

  describe "the protocol" do
    test "the hook gets Claude Code PreToolUse JSON on stdin", %{dir: dir} do
      out = Path.join(dir, "input.json")
      assert {:ok, _} = ApprovalHook.handle(config(script(dir, "cat > #{out}\n")), payload())

      assert %{
               "hook_event_name" => "PreToolUse",
               "tool_name" => "shell_execute",
               "tool_input" => %{"command" => "git push"},
               "tool_use_id" => "call_42",
               "session_id" => "s-approval",
               "cwd" => "/workspace",
               "permission_mode" => "default",
               "transcript_path" => ""
             } = out |> File.read!() |> Jason.decode!()
    end

    test "exit 0 with no output allows", %{dir: dir} do
      assert {:ok, %{tool_name: "shell_execute"}} =
               ApprovalHook.handle(config(script(dir, "cat >/dev/null\nexit 0\n")), payload())
    end

    test "exit 2 denies with the reason from stdout", %{dir: dir} do
      hook =
        script(dir, "cat >/dev/null\necho 'pushes need a person'\necho 'ignored' >&2\nexit 2\n")

      assert ApprovalHook.handle(config(hook), payload()) == {:block, "pushes need a person"}
    end

    test "exit 2 with only stderr still has a reason", %{dir: dir} do
      hook = script(dir, "cat >/dev/null\necho 'from stderr' >&2\nexit 2\n")
      assert ApprovalHook.handle(config(hook), payload()) == {:block, "from stderr"}
    end

    test "exit 2 with a JSON body uses its reason field", %{dir: dir} do
      hook =
        script(dir, """
        cat >/dev/null
        printf '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"json reason"}}'
        exit 2
        """)

      assert ApprovalHook.handle(config(hook), payload()) == {:block, "json reason"}
    end

    test "MIOSA gate output: a Claude deny on exit 0, with and without stopping the run",
         %{dir: dir} do
      deny =
        script(dir, """
        cat >/dev/null
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\\n' "Never: publishing is off"
        exit 0
        """)

      assert ApprovalHook.handle(config(deny), payload()) == {:block, "Never: publishing is off"}

      stop =
        script(dir, """
        cat >/dev/null
        printf '{"continue":false,"stopReason":"denied and stopped","hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"x"}}'
        """)

      assert ApprovalHook.handle(config(stop), payload()) == {:block, "denied and stopped"}
    end

    test "allow and ask decisions", %{dir: dir} do
      allow =
        script(
          dir,
          ~s(cat >/dev/null\nprintf '{"hookSpecificOutput":{"permissionDecision":"allow"}}'\n)
        )

      assert {:ok, %{permission_decision: :allow}} = ApprovalHook.handle(config(allow), payload())

      ask =
        script(
          dir,
          ~s(cat >/dev/null\nprintf '{"hookSpecificOutput":{"permissionDecision":"ask"}}'\n)
        )

      assert {:block, reason} = ApprovalHook.handle(config(ask), payload())
      assert reason =~ "nobody can answer"
    end

    test "updatedInput rewrites the arguments", %{dir: dir} do
      hook =
        script(dir, """
        cat >/dev/null
        printf '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"git push --dry-run"}}}'
        """)

      assert {:ok, %{arguments: %{"command" => "git push --dry-run"}}} =
               ApprovalHook.handle(config(hook), payload())
    end
  end

  describe "fails closed" do
    test "on any other exit code", %{dir: dir} do
      hook = script(dir, "cat >/dev/null\necho boom >&2\nexit 7\n")
      assert {:block, reason} = ApprovalHook.handle(config(hook), payload())
      assert reason =~ "exit 7"
    end

    test "when it does not answer in time", %{dir: dir} do
      hook = script(dir, "cat >/dev/null\nsleep 5\n")
      assert {:block, reason} = ApprovalHook.handle(config(hook, timeout_ms: 300), payload())
      assert reason =~ "did not answer"
    end

    test "when the command does not exist" do
      assert {:block, _} =
               ApprovalHook.handle(config("/nonexistent/osa-approval-gate.sh"), payload())
    end

    test "a tool outside the matcher is not asked", %{dir: dir} do
      hook = script(dir, "exit 2\n")
      assert {:ok, _} = ApprovalHook.handle(config(hook, matcher: "mcp__.*"), payload())
    end
  end

  describe "ToolExecutor routing of an unattended approval" do
    setup do
      prior =
        Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)

      sid = "approval-route-#{System.unique_integer([:positive])}"
      Attendance.put_channel(sid, :headless)

      on_exit(fn ->
        Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, prior)
        PermissionMode.clear(sid)
      end)

      call = %{
        id: "tc_#{System.unique_integer([:positive])}",
        name: "file_write",
        arguments: %{
          "path" => Path.join(System.tmp_dir!(), "osa_route_probe.txt"),
          "content" => "x"
        }
      }

      {:ok, sid: sid, call: call}
    end

    defp state(sid, mode \\ :ask),
      do:
        struct(OptimalSystemAgent.Agent.Loop,
          session_id: sid,
          channel: :headless,
          permission_mode: mode
        )

    test "no hook: the call that needs approval is refused", %{sid: sid, call: call} do
      assert {:blocked, message} = ToolExecutor.approve_tool_call(call, state(sid))
      assert message =~ "fail closed"
    end

    test "a covering hook decides instead", %{sid: sid, call: call} do
      ApprovalHook.register(config("true"))
      assert ToolExecutor.approve_tool_call(call, state(sid)) == :allow
    end

    test "a hook that does not cover the tool changes nothing", %{sid: sid, call: call} do
      ApprovalHook.register(config("true", matcher: "shell_execute"))
      assert {:blocked, _} = ToolExecutor.approve_tool_call(call, state(sid))
    end

    test "overdrive allows without asking", %{sid: sid, call: call} do
      PermissionMode.put(sid, :overdrive)
      assert ToolExecutor.approve_tool_call(call, state(sid, :overdrive)) == :allow
    end

    test "a protected path stays refused, hook or not", %{sid: sid} do
      ApprovalHook.register(config("true"))

      git_write = %{
        id: "tc_git",
        name: "file_write",
        arguments: %{"path" => Path.join(File.cwd!(), ".git/config"), "content" => "x"}
      }

      assert {:blocked, _} = ToolExecutor.approve_tool_call(git_write, state(sid))
    end

    test "the hook sees the session's mode in Claude Code's vocabulary", %{sid: sid} do
      assert ToolExecutor.hook_permission_mode(state(sid)) == "default"
      PermissionMode.put(sid, :overdrive)
      assert ToolExecutor.hook_permission_mode(state(sid)) == "bypassPermissions"
      PermissionMode.put(sid, :plan)
      assert ToolExecutor.hook_permission_mode(state(sid)) == "plan"
      PermissionMode.put(sid, :accept_edits)
      assert ToolExecutor.hook_permission_mode(state(sid)) == "acceptEdits"
    end
  end
end
