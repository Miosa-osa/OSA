defmodule OptimalSystemAgent.Agent.Loop.PermissionEnforcementTest do
  @moduledoc """
  Group B — permission enforcement round-trip + modes.

  Covers:
    * permission_mode gating in `ToolExecutor.approve_tool_call/2`
      (:overdrive / :plan / :accept_edits / :ask)
    * the interactive ask decision (`{:ask, request_id, summary}`) and that
      interactive prompts stay OFF unless enabled (no regression)
    * `PermissionBroker` park/respond/cancel + session-scoped allow
    * `apply_permission_decision/4`: allow-always persists a rule, deny-always
      persists a deny rule, allow-session remembers, reject-with-steer returns
      the user's clarify text
    * `Loop.set_permission_mode/2` (+ :bypass alias, invalid rejection)
    * the `POST /permissions/respond` HTTP endpoint
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes
  alias OptimalSystemAgent.Permissions

  @cancel_table :osa_cancel_flags
  @route_opts ToolRoutes.init([])

  setup do
    # Fresh saved-rule store each test (test.exs points it at a tmp file).
    file = Application.get_env(:optimal_system_agent, :permissions_file)
    if is_binary(file), do: File.rm(file)

    # Interactive prompts default OFF in the test env; each test opts in.
    prior = Application.get_env(:optimal_system_agent, :interactive_permissions, false)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :interactive_permissions, prior) end)

    :ok
  end

  defp state(overrides \\ []) do
    struct(Loop, [session_id: "perm-test-#{unique()}"] ++ overrides)
  end

  defp tool(name, args \\ %{}), do: %{id: "tc-#{unique()}", name: name, arguments: args}

  defp unique, do: System.unique_integer([:positive, :monotonic])

  defp enable_interactive, do: Application.put_env(:optimal_system_agent, :interactive_permissions, true)

  # ── permission_mode gating ──────────────────────────────────────────

  describe "approve_tool_call/2 mode gating" do
    test ":overdrive allows a mutating tool" do
      s = state(permission_mode: :overdrive)
      assert :allow = ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)
    end

    test "a write to a protected dotfile is BLOCKED before asking (never ask-then-deny)" do
      # Regression: the operator was prompted to approve a write the handler
      # would unconditionally reject at execute time, so "yes" produced an
      # "Access denied" — approval was meaningless. The handler hard path-guard
      # is now consulted up front and blocks with the real reason instead.
      s = state(permission_mode: :ask)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "~/.zshrc", "content" => "x"}),
                 s
               )

      assert msg =~ "protected dotfile"
    end

    test "the dotfile hard-deny holds even in :overdrive (never allow-then-fail)" do
      # Overdrive must not "allow" a write that then fails at execute; the hard
      # path-guard is ordered before the mode short-circuits for this reason.
      s = state(permission_mode: :overdrive)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "~/.zshrc", "content" => "x"}),
                 s
               )

      assert msg =~ "protected dotfile"
    end

    test ":plan denies a mutating tool" do
      s = state(permission_mode: :plan)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)

      assert msg =~ "plan mode"
    end

    test ":plan allows a read-only tool" do
      s = state(permission_mode: :plan)
      assert :allow = ToolExecutor.approve_tool_call(tool("file_read", %{"path" => "a.txt"}), s)
    end

    test ":accept_edits auto-allows an edit tool" do
      s = state(permission_mode: :accept_edits)

      assert :allow =
               ToolExecutor.approve_tool_call(
                 tool("file_edit", %{"old_string" => "a", "new_string" => "b"}),
                 s
               )
    end

    test ":accept_edits still defers non-edit mutating tools to tier/ask" do
      # interactive OFF → tier (:full) decision stands → allow
      s = state(permission_mode: :accept_edits)
      assert :allow = ToolExecutor.approve_tool_call(tool("shell_execute", %{"command" => "ls"}), s)

      # interactive ON → a non-edit mutating tool must ask, not silently run
      enable_interactive()
      s2 = state(permission_mode: :accept_edits)

      assert {:ask, _rid, _summary} =
               ToolExecutor.approve_tool_call(tool("shell_execute", %{"command" => "ls"}), s2)
    end

    test ":ask with interactive OFF preserves prior behavior (allow at :full)" do
      s = state(permission_mode: :ask)
      assert :allow = ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)
    end

    test ":ask with interactive ON parks a mutating tool for approval" do
      enable_interactive()
      s = state(permission_mode: :ask)

      assert {:ask, request_id, summary} =
               ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)

      assert is_binary(request_id)
      assert summary.tool == "file_write"
    end

    test ":ask never prompts for a read-only tool even with interactive ON" do
      enable_interactive()
      s = state(permission_mode: :ask)
      assert :allow = ToolExecutor.approve_tool_call(tool("file_read", %{"path" => "a.txt"}), s)
    end

    test "a saved allow rule short-circuits the prompt" do
      enable_interactive()
      Permissions.save_rule("file_write", :allow_always)
      s = state(permission_mode: :ask)
      assert :allow = ToolExecutor.approve_tool_call(tool("file_write", %{"path" => "a.txt"}), s)
    end

    test "a saved deny rule blocks without prompting" do
      enable_interactive()
      tool_name = "probe_#{unique()}"
      Permissions.save_rule(tool_name, :deny_always)
      s = state(permission_mode: :ask)
      assert {:blocked, _} = ToolExecutor.approve_tool_call(tool(tool_name), s)
    end
  end

  # ── PermissionBroker park / respond / cancel ────────────────────────

  describe "PermissionBroker round-trip" do
    test "await resumes when a decision is posted" do
      rid = PermissionBroker.new_request_id()
      sid = "sess-#{unique()}"

      task = Task.async(fn -> PermissionBroker.await(sid, rid, timeout: 5_000) end)
      # Give the poller a moment, then respond.
      Process.sleep(50)
      PermissionBroker.respond(rid, %{"decision" => "allow"})

      assert {:ok, %{decision: :allow_once}} = Task.await(task, 6_000)
    end

    test "await aborts when the session is cancelled" do
      rid = PermissionBroker.new_request_id()
      sid = "sess-#{unique()}"
      ensure_cancel_table()

      task = Task.async(fn -> PermissionBroker.await(sid, rid, timeout: 5_000) end)
      Process.sleep(50)
      :ets.insert(@cancel_table, {sid, true})

      assert {:error, :cancelled} = Task.await(task, 6_000)
      :ets.delete(@cancel_table, sid)
    end

    test "clarify decision carries the note through" do
      rid = PermissionBroker.new_request_id()
      sid = "sess-#{unique()}"

      task = Task.async(fn -> PermissionBroker.await(sid, rid, timeout: 5_000) end)
      Process.sleep(50)
      PermissionBroker.respond(rid, %{"decision" => "clarify", "note" => "use a temp dir instead"})

      assert {:ok, %{decision: :clarify, note: "use a temp dir instead"}} = Task.await(task, 6_000)
    end

    test "session-scoped allow is remembered" do
      sid = "sess-#{unique()}"
      refute PermissionBroker.session_allowed?(sid, "file_write")
      PermissionBroker.allow_for_session(sid, "file_write")
      assert PermissionBroker.session_allowed?(sid, "file_write")
    end
  end

  # ── apply_permission_decision/4 ─────────────────────────────────────

  describe "apply_permission_decision/4" do
    test ":allow_always persists a reusable allow rule" do
      name = "probe_#{unique()}"
      s = state()
      assert :allow = ToolExecutor.apply_permission_decision(:allow_always, nil, tool(name), s)
      assert Permissions.check(name) == :allow
    end

    test ":deny_always persists a reusable deny rule and blocks" do
      name = "probe_#{unique()}"
      s = state()
      assert {:blocked, _} = ToolExecutor.apply_permission_decision(:deny_always, nil, tool(name), s)
      assert Permissions.check(name) == :deny
    end

    test ":allow_session remembers the grant for the session" do
      s = state()
      name = "probe_#{unique()}"
      assert :allow = ToolExecutor.apply_permission_decision(:allow_session, nil, tool(name), s)
      assert PermissionBroker.session_allowed?(s.session_id, name)
    end

    test ":clarify returns the user's steer text (reject-with-steer)" do
      s = state()

      assert {:steer, "run the read-only variant"} =
               ToolExecutor.apply_permission_decision(
                 :clarify,
                 "run the read-only variant",
                 tool("shell_execute"),
                 s
               )
    end

    test ":clarify with empty note falls back to a block" do
      s = state()
      assert {:blocked, _} = ToolExecutor.apply_permission_decision(:clarify, "  ", tool("x"), s)
    end

    test ":allow_once runs without persisting anything" do
      name = "probe_#{unique()}"
      s = state()
      assert :allow = ToolExecutor.apply_permission_decision(:allow_once, nil, tool(name), s)
      assert Permissions.check(name) == :ask
    end
  end

  # ── Loop.set_permission_mode/2 ──────────────────────────────────────

  describe "Loop permission_mode setter" do
    setup do
      session_id = "mode-#{unique()}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: session_id, channel: :test}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      %{session_id: session_id, pid: pid}
    end

    test "defaults to :ask", ctx do
      assert {:ok, :ask} = Loop.get_permission_mode(ctx.session_id)
    end

    test "accepts each mode", ctx do
      for mode <- [:ask, :accept_edits, :plan, :overdrive] do
        assert {:ok, ^mode} = Loop.set_permission_mode(ctx.session_id, mode)
        assert {:ok, ^mode} = Loop.get_permission_mode(ctx.session_id)
      end
    end

    test ":bypass is a silent alias for :overdrive", ctx do
      assert {:ok, :overdrive} = Loop.set_permission_mode(ctx.session_id, :bypass)
    end

    test "rejects an unknown mode without killing the session", ctx do
      assert {:error, :invalid_mode} = Loop.set_permission_mode(ctx.session_id, :bogus)
      assert Process.alive?(ctx.pid)
    end
  end

  # ── POST /permissions/respond endpoint ──────────────────────────────

  describe "POST /permissions/respond" do
    test "resumes a parked request end-to-end" do
      rid = PermissionBroker.new_request_id()
      sid = "sess-#{unique()}"

      task = Task.async(fn -> PermissionBroker.await(sid, rid, timeout: 5_000) end)
      Process.sleep(50)

      conn = post_respond(%{request_id: rid, decision: "always"})
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ok"

      assert {:ok, %{decision: :allow_always}} = Task.await(task, 6_000)
    end

    test "400 when request_id is missing" do
      conn = post_respond(%{decision: "allow"})
      assert conn.status == 400
    end

    test "400 when decision is missing" do
      conn = post_respond(%{request_id: "perm_1"})
      assert conn.status == 400
    end
  end

  defp post_respond(body) do
    conn(:post, "/respond", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> ToolRoutes.call(@route_opts)
  end

  defp ensure_cancel_table do
    case :ets.whereis(@cancel_table) do
      :undefined -> :ets.new(@cancel_table, [:named_table, :public])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
