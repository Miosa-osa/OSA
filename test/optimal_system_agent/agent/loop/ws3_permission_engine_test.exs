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

  test "bypass-immune safety ask prompts for .git writes even in :overdrive" do
    enable_interactive()

    assert {:ask, _rid, summary} =
             ToolExecutor.approve_tool_call(
               tool("file_write", %{"path" => ".git/config", "content" => "x"}),
               state(permission_mode: :overdrive)
             )

    assert summary.reason =~ "Safety check"
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
end
