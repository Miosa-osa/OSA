defmodule OptimalSystemAgent.Agent.Loop.OverdriveStickinessTest do
  @moduledoc """
  Regression coverage for the live TUI edge cases:

    * BUG 1 — overdrive must bypass permission prompts (except the hard
      circuit-breaker), and that choice must be STICKY: it survives a loop that
      is created after the toggle (`{:error, :no_session}` race), a loop
      (re)created fresh for the session, and it is inherited by a subagent
      spawned under an overdrive parent — while the subagent's structural tool
      restrictions and the bypass-immune safety asks still hold.

    * BUG 2 — the permission prompt names the real target (skill name, shell
      command, file path), not just the generic tool name.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.PermissionMode
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Permissions

  setup do
    file = Application.get_env(:optimal_system_agent, :permissions_file)
    if is_binary(file), do: File.rm(file)

    prior = Application.get_env(:optimal_system_agent, :interactive_permissions, false)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :interactive_permissions, prior) end)
    :ok
  end

  defp state(overrides \\ []), do: struct(Loop, [session_id: "od-#{unique()}"] ++ overrides)
  defp tool(name, args \\ %{}), do: %{id: "tc-#{unique()}", name: name, arguments: args}
  defp unique, do: System.unique_integer([:positive, :monotonic])
  defp enable_interactive, do: Application.put_env(:optimal_system_agent, :interactive_permissions, true)

  # ── BUG 1: overdrive bypasses prompts ───────────────────────────────

  describe "overdrive gate" do
    test "allows use_skill (the reported case) without an ask" do
      s = state(permission_mode: :overdrive)
      assert :allow = ToolExecutor.approve_tool_call(tool("use_skill", %{"skill_name" => "lavish"}), s)
    end

    test "allows a normal mutating tool without an ask" do
      s = state(permission_mode: :overdrive)
      assert :allow = ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)
    end

    test "the circuit-breaker still blocks a catastrophic command under overdrive" do
      s = state(permission_mode: :overdrive)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(
                 tool("shell_execute", %{"command" => "rm -rf /"}),
                 s
               )

      assert msg =~ "hard safety limit"
    end

    test "use_skill is NOT wrongly flagged as a bypass-immune safety ask" do
      assert Permissions.bypass_immune_ask("use_skill", %{"skill_name" => "lavish"}) == nil
    end

    test "bypass-immune write to .git internals still asks even under overdrive" do
      enable_interactive()
      s = state(permission_mode: :overdrive)

      path = Path.join([OptimalSystemAgent.Workspace.Cwd.get(), ".git", "config"])
      assert {:ask, _rid, summary} = ToolExecutor.approve_tool_call(tool("file_write", %{"path" => path}), s)
      assert summary.reason =~ "not bypassable"
    end
  end

  # ── BUG 1: subagent inherits overdrive, keeps structural limits ─────

  describe "subagent under overdrive" do
    test "inherited overdrive allows a normal tool for a subagent" do
      s = state(permission_mode: :overdrive, permission_tier: :subagent)
      assert :allow = ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)
    end

    test "overdrive does NOT open the subagent's blocked spawning tools" do
      s = state(permission_mode: :overdrive, permission_tier: :subagent)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(tool("delegate", %{"task" => "x"}), s)

      assert msg =~ "does not have access"
    end

    test "overdrive respects a per-agent denylist" do
      s =
        state(
          permission_mode: :overdrive,
          permission_tier: :subagent,
          blocked_tools: ["file_write"]
        )

      assert {:blocked, _} = ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)
    end
  end

  # ── BUG 1: stickiness across a fresh / late loop ────────────────────

  describe "sticky permission mode" do
    test "set on a non-existent session is recorded and reported pending, not lost" do
      sid = "ghost-#{unique()}"
      # No loop exists for this session id.
      assert {:ok, :overdrive} = Loop.set_permission_mode(sid, :overdrive)
      assert PermissionMode.get(sid) == :overdrive
    end

    test "a fresh loop inherits the sticky mode over the settings default" do
      sid = "sticky-#{unique()}"
      PermissionMode.put(sid, :overdrive)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: sid, channel: :test}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert {:ok, :overdrive} = Loop.get_permission_mode(sid)
    end

    test "an explicit permission_mode opt still wins over the sticky store" do
      sid = "explicit-#{unique()}"
      PermissionMode.put(sid, :overdrive)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: sid, channel: :test, permission_mode: :plan}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert {:ok, :plan} = Loop.get_permission_mode(sid)
    end

    test "the no-session race then loop start yields an overdrive turn end-to-end" do
      sid = "race-#{unique()}"
      # (1) TUI toggles overdrive before the turn's loop exists.
      assert {:ok, :overdrive} = Loop.set_permission_mode(sid, :overdrive)

      # (2) The loop for the turn starts afterwards with no explicit mode.
      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: sid, channel: :test}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      # (3) The turn runs in overdrive — the choice was NOT lost.
      assert {:ok, :overdrive} = Loop.get_permission_mode(sid)
    end
  end

  # ── BUG 2: prompt names the real target ─────────────────────────────

  describe "permission_summary target" do
    setup do
      enable_interactive()
      :ok
    end

    defp summary_for(tool_call) do
      case ToolExecutor.approve_tool_call(tool_call, state(permission_mode: :ask, permission_tier: :full)) do
        {:ask, _rid, summary} -> summary
        other -> flunk("expected an :ask, got #{inspect(other)}")
      end
    end

    test "use_skill surfaces the skill name" do
      s = summary_for(tool("use_skill", %{"skill_name" => "lavish", "task" => "make a chart"}))
      assert s.target == "skill: lavish"
      assert s.tool == "use_skill"
    end

    test "shell surfaces the command" do
      s = summary_for(tool("shell_execute", %{"command" => "npm test"}))
      assert s.target == "npm test"
    end

    test "file_edit surfaces the path" do
      s = summary_for(tool("file_edit", %{"path" => "lib/foo.ex", "old_string" => "a", "new_string" => "b"}))
      assert s.target == "edit lib/foo.ex"
    end

    test "an unmapped mutating tool falls back to a nil target (tool name shown)" do
      s = summary_for(tool("memory_write", %{"content" => "note"}))
      assert s.target == nil
      assert s.tool == "memory_write"
    end
  end
end
