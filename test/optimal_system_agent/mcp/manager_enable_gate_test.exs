defmodule OptimalSystemAgent.MCP.ManagerEnableGateTest do
  @moduledoc """
  Tests the enable_server approval gate: a project-scope MCP server the operator
  has NOT approved must refuse to enable (`{:error, :requires_approval}`), while
  user-scope servers are ungated. Covers the security fix closing the bypass
  where `enable_server` started any server without an approval check.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.MCP.Client.Manager
  alias OptimalSystemAgent.MCP.Config.Server
  alias OptimalSystemAgent.MCP.ProjectApproval

  setup do
    # Isolate the project-choices file under a fresh tmp config dir so approval
    # state never touches the operator's real ~/.osa.
    tmp = Path.join(System.tmp_dir!(), "osa_mcp_enable_#{System.unique_integer([:positive])}")
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

  describe "enable_authorized?/1" do
    test "unapproved project server is not authorized" do
      refute Manager.enable_authorized?(%Server{name: "repo_srv", scope: :project})
    end

    test "approved project server is authorized" do
      :ok = ProjectApproval.approve("repo_srv")
      assert Manager.enable_authorized?(%Server{name: "repo_srv", scope: :project})
    end

    test "user-scope server is always authorized" do
      assert Manager.enable_authorized?(%Server{name: "user_srv", scope: :user})
    end

    test "local-scope server is always authorized" do
      assert Manager.enable_authorized?(%Server{name: "local_srv", scope: :local})
    end
  end

  describe "handle_call({:enable_server, ...})" do
    test "refuses an unapproved project server with :requires_approval" do
      server = %Server{name: "repo_srv", scope: :project, enabled: false}
      state = %Manager{servers: %{"repo_srv" => server}}

      assert {:reply, {:error, :requires_approval}, ^state} =
               Manager.handle_call(
                 {:enable_server, "repo_srv"},
                 {self(), make_ref()},
                 state
               )
    end

    test "unknown, unconfigured server is :not_found" do
      state = %Manager{servers: %{}}

      assert {:reply, {:error, :not_found}, ^state} =
               Manager.handle_call(
                 {:enable_server, "does_not_exist_#{System.unique_integer([:positive])}"},
                 {self(), make_ref()},
                 state
               )
    end
  end
end
