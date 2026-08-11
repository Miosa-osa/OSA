defmodule OptimalSystemAgent.Agent.Loop.WS3PermissionEngineTest do
  @moduledoc """
  WS3 executor integration: settings-cascade deny beats :overdrive,
  bypass-immune safety asks prompt in every mode, enriched permission
  summaries (kind/diff/warning/reason/suggestions), and interactive
  "Always" persisting scoped prefix rules.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Settings

  @flag_file Path.join(System.tmp_dir!(), "osa-ws3-exec-settings.json")

  setup do
    legacy = Application.get_env(:optimal_system_agent, :permissions_file)
    if is_binary(legacy), do: File.rm(legacy)

    prior_flag = Application.get_env(:optimal_system_agent, :settings_flag_path)

    prior_interactive =
      Application.get_env(:optimal_system_agent, :interactive_permissions, false)

    on_exit(fn ->
      case prior_flag do
        nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
        path -> Application.put_env(:optimal_system_agent, :settings_flag_path, path)
      end

      Application.put_env(:optimal_system_agent, :interactive_permissions, prior_interactive)
      File.rm(@flag_file)
      if is_binary(legacy), do: File.rm(legacy)
      Settings.reset_cache()
    end)

    :ok
  end

  defp state(overrides \\ []),
    do: struct(Loop, [session_id: "ws3-#{System.unique_integer([:positive])}"] ++ overrides)

  defp tool(name, args \\ %{}),
    do: %{id: "tc-#{System.unique_integer([:positive])}", name: name, arguments: args}

  defp enable_interactive,
    do: Application.put_env(:optimal_system_agent, :interactive_permissions, true)

  defp put_flag_permissions(perms) do
    File.write!(@flag_file, Jason.encode!(%{"permissions" => perms}))
    Application.put_env(:optimal_system_agent, :settings_flag_path, @flag_file)
    Settings.reset_cache()
  end

  test "settings-cascade deny rule blocks in :overdrive" do
    put_flag_permissions(%{"deny" => ["file_write"]})

    assert {:blocked, msg} =
             ToolExecutor.approve_tool_call(
               tool("file_write", %{"path" => "a.txt"}),
               state(permission_mode: :overdrive)
             )

    assert msg =~ "denied by a saved permission rule"
  end

  test "bypass-immune safety refuses .git writes outright, even in :overdrive" do
    enable_interactive()

    # This used to prompt. It now blocks, which is deliberately stronger: a write
    # into .git internals is code execution on the user's next git command
    # (core.hooksPath, core.fsmonitor, filter.*.clean), and `Git.cmd/2` only
    # neutralizes those for OSA's own invocations — not for the user's shell.
    # An approval prompt puts that one keystroke away in a mode whose whole
    # point is not stopping to ask, so the path is refused rather than offered.
    assert {:blocked, msg} =
             ToolExecutor.approve_tool_call(
               tool("file_write", %{"path" => ".git/config", "content" => "x"}),
               state(permission_mode: :overdrive)
             )

    assert msg =~ "protected location"
  end

  test "enriched summary: file_edit diff + kind + suggestions" do
    enable_interactive()

    assert {:ask, _rid, summary} =
             ToolExecutor.approve_tool_call(
               tool("file_edit", %{"path" => "a.ex", "old_string" => "x", "new_string" => "y"}),
               state(permission_mode: :ask)
             )

    assert summary.kind == "file_edit"
    assert summary.old_content == "x"
    assert summary.new_content == "y"
    assert [%{type: "addRules"} | _] = summary.suggestions
  end

  test "enriched summary: destructive shell warning" do
    enable_interactive()

    assert {:ask, _rid, summary} =
             ToolExecutor.approve_tool_call(
               tool("shell_execute", %{"command" => "git reset --hard"}),
               state(permission_mode: :ask)
             )

    assert summary.kind == "bash"
    assert summary.warning =~ "may discard"
  end

  test "ask rule forces a prompt past a broader allow rule" do
    enable_interactive()
    put_flag_permissions(%{"allow" => ["shell_execute"], "ask" => ["shell_execute(git push:*)"]})

    assert :allow =
             ToolExecutor.approve_tool_call(
               tool("shell_execute", %{"command" => "ls"}),
               state(permission_mode: :ask)
             )

    assert {:ask, _rid, summary} =
             ToolExecutor.approve_tool_call(
               tool("shell_execute", %{"command" => "git push origin main"}),
               state(permission_mode: :ask)
             )

    assert summary.reason =~ "ask rule"
  end

  test "interactive Always persists a scoped shell prefix rule" do
    s = state()

    assert :allow =
             ToolExecutor.apply_permission_decision(
               :allow_always,
               nil,
               tool("shell_execute", %{"command" => "npm run build"}),
               s
             )

    assert Permissions.check("shell_execute", %{"command" => "npm run build --verbose"}) ==
             :allow

    assert Permissions.check("shell_execute", %{"command" => "ls"}) == :ask
  end

  # ── accept_edits: auto-allow is narrowed to in-scope, unruled edits ──
  #
  # M1 / finding #5: accept_edits used to auto-allow ANY @edit_tools call —
  # including a write to an out-of-workspace absolute path, and it never
  # consulted a saved `ask` rule at all (maybe_ask/2 was never reached). Both
  # must still prompt; only a genuinely in-scope, unruled edit auto-runs.
  describe "accept_edits scope + ask-rule guard" do
    test "auto-allows an in-scope edit with no matching rule" do
      s = state(permission_mode: :accept_edits)

      assert :allow =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "ws3-in-scope.txt", "content" => "x"}),
                 s
               )
    end

    test "still ASKS (not auto-allow) for a write outside the workspace scope" do
      enable_interactive()
      s = state(permission_mode: :accept_edits)

      # A legitimately writable but out-of-workspace path (the handler's own
      # path-guard ALLOWS it — it is not a protected/system location), so the
      # accept_edits out-of-scope prompt is the real gate. A hard-protected path
      # like /etc/passwd is exercised separately below (it blocks before asking,
      # since asking to approve a write the handler will always reject is exactly
      # the ask-then-deny bug).
      assert {:ask, _rid, summary} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "~/projects/elsewhere/oos.txt", "content" => "x"}),
                 s
               )

      assert summary.reason =~ "outside the workspace"
    end

    test "a hard-protected path BLOCKS before asking, even in accept_edits" do
      # Regression for the live "I approved but it says Access denied" bug: a
      # path the handler unconditionally rejects (/etc/passwd, a dotfile, …) must
      # not be presented as an approvable prompt. It is blocked up front with the
      # real reason instead.
      enable_interactive()
      s = state(permission_mode: :accept_edits)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "/etc/passwd", "content" => "pwned"}),
                 s
               )

      assert msg =~ "protected" or msg =~ "outside allowed"
    end

    test "out-of-scope write fails closed (not silently allowed) when non-interactive and no bypass" do
      prior_bypass =
        Application.get_env(:optimal_system_agent, :non_interactive_permission_bypass, true)

      Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, false)
      on_exit(fn -> Application.put_env(:optimal_system_agent, :non_interactive_permission_bypass, prior_bypass) end)

      s = state(permission_mode: :accept_edits)

      # Benign out-of-scope path (handler allows it), so the block here comes from
      # the non-interactive out-of-scope fail-closed rule, not the hard path-guard.
      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "~/projects/elsewhere/oos.txt", "content" => "x"}),
                 s
               )

      assert msg =~ "requires interactive approval"
    end

    test "still ASKS (not auto-allow) for a path matching a saved ask rule" do
      enable_interactive()
      put_flag_permissions(%{"ask" => ["file_write(ws3-secret.txt)"]})
      s = state(permission_mode: :accept_edits)

      assert {:ask, _rid, summary} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "ws3-secret.txt", "content" => "x"}),
                 s
               )

      assert summary.reason =~ "ask rule"
    end

    test "a saved DENY rule still blocks accept_edits outright" do
      put_flag_permissions(%{"deny" => ["file_write(ws3-secret.txt)"]})
      s = state(permission_mode: :accept_edits)

      assert {:blocked, msg} =
               ToolExecutor.approve_tool_call(
                 tool("file_write", %{"path" => "ws3-secret.txt", "content" => "x"}),
                 s
               )

      assert msg =~ "denied by a saved permission rule"
    end
  end

  # ── multi_file_edit: permission prompt must name the files ───────────
  #
  # M3 / finding #5: the approval prompt showed neither a target nor a diff
  # for multi_file_edit (args have no top-level `path`), so the user approved
  # a multi-file mutation blind.
  describe "multi_file_edit permission prompt" do
    test "names every target file and shows a per-file diff" do
      enable_interactive()

      edits = [
        %{"path" => "a.ex", "old_string" => "foo", "new_string" => "bar"},
        %{"path" => "b.ex", "old_string" => "baz", "new_string" => "qux"}
      ]

      assert {:ask, _rid, summary} =
               ToolExecutor.approve_tool_call(
                 tool("multi_file_edit", %{"edits" => edits}),
                 state(permission_mode: :ask)
               )

      assert summary.target =~ "a.ex"
      assert summary.target =~ "b.ex"
      assert summary.target =~ "2 files"
      assert summary.old_content =~ "foo"
      assert summary.old_content =~ "baz"
      assert summary.new_content =~ "bar"
      assert summary.new_content =~ "qux"
    end

    test "out-of-scope multi_file_edit path still prompts even in accept_edits" do
      enable_interactive()
      s = state(permission_mode: :accept_edits)

      edits = [
        %{"path" => "a.ex", "old_string" => "foo", "new_string" => "bar"},
        %{"path" => "~/projects/elsewhere/oos.ex", "old_string" => "foo", "new_string" => "bar"}
      ]

      assert {:ask, _rid, summary} =
               ToolExecutor.approve_tool_call(
                 tool("multi_file_edit", %{"edits" => edits}),
                 s
               )

      assert summary.reason =~ "outside the workspace"
    end
  end
end
