defmodule OptimalSystemAgent.MCP.ScopesPermissionsTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.{Config, ProjectApproval}
  alias OptimalSystemAgent.Permissions

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_mcp_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      File.rm_rf(tmp)
    end)

    :ok
  end

  test "add_server then load_scope round-trips (user scope)" do
    assert {:ok, _path} = Config.add_server("gh", %{"command" => "gh-mcp"}, :user)
    assert [%{name: "gh", scope: :user}] = Config.load_scope(:user)
  end

  test "remove_server deletes from scope" do
    Config.add_server("gh", %{"command" => "x"}, :user)
    assert {:ok, _} = Config.remove_server("gh", :user)
    assert Config.load_scope(:user) == []
  end

  test "project approval gates approved?" do
    refute ProjectApproval.approved?("repo_srv")
    ProjectApproval.approve("repo_srv")
    assert ProjectApproval.approved?("repo_srv")
    ProjectApproval.reset()
    refute ProjectApproval.approved?("repo_srv")
  end

  test "mcp server-level and wildcard permission rules match" do
    pf = Path.join(System.tmp_dir!(), "perm_#{System.unique_integer([:positive])}.json")
    File.write!(pf, Jason.encode!(%{"mcp__github" => "allow", "mcp__linear__*" => "deny"}))
    prev = Application.get_env(:optimal_system_agent, :permissions_file)
    Application.put_env(:optimal_system_agent, :permissions_file, pf)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :permissions_file, prev),
        else: Application.delete_env(:optimal_system_agent, :permissions_file)

      File.rm(pf)
    end)

    assert Permissions.check("mcp__github__create_issue") == :allow
    assert Permissions.check("mcp__linear__search_issues") == :deny
    assert Permissions.check("mcp__unknown__tool") == :ask
  end
end
