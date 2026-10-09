defmodule OptimalSystemAgent.CLI.Headless.SessionTest do
  @moduledoc """
  Which session `osa run` continues: `--resume`, `--continue`, `--session-id`
  and a fresh run, against the real session store, plus the MCP servers named
  on the command line.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.CLI.Headless
  alias OptimalSystemAgent.CLI.Headless.Options
  alias OptimalSystemAgent.MCP.Config

  @moduletag :tmp_dir

  defp opts(argv) do
    {:ok, opts} = Options.parse(argv)
    opts
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "resolve_session/2" do
    test "a fresh run gets a new headless id", %{tmp_dir: cwd} do
      assert {:ok, %{id: "headless-" <> _, resumed: false, working_dir: ^cwd}} =
               Headless.resolve_session(opts([]), cwd)
    end

    test "--resume needs a transcript on disk; missing is :missing (exit 79)", %{tmp_dir: cwd} do
      id = unique("resume-missing")
      assert {:missing, message} = Headless.resolve_session(opts(["--resume", id]), cwd)
      assert message =~ id
      assert Headless.session_missing_exit() == 79
    end

    test "--resume finds a saved session and runs in its directory", %{tmp_dir: cwd} do
      id = unique("resume-found")
      saved_dir = Path.join(cwd, "project")
      File.mkdir_p!(saved_dir)

      :ok =
        SessionPersistence.save(id, [%{role: "user", content: "REMEMBER x=y"}], saved_dir)

      assert {:ok, %{id: ^id, resumed: true, working_dir: ^saved_dir}} =
               Headless.resolve_session(opts(["--resume", id]), cwd)

      # An explicit --cwd wins over the saved directory.
      assert {:ok, %{working_dir: ^cwd}} =
               Headless.resolve_session(opts(["--resume", id, "--cwd", cwd]), cwd)
    end

    test "--continue picks the newest session saved for the directory", %{tmp_dir: cwd} do
      assert {:missing, _} = Headless.resolve_session(opts(["--continue"]), cwd)

      id = unique("continue")
      :ok = SessionPersistence.save(id, [%{role: "user", content: "hi"}], cwd)

      assert {:ok, %{id: ^id, resumed: true}} =
               Headless.resolve_session(opts(["--continue"]), cwd)
    end

    test "--session-id starts that session, and refuses one that exists", %{tmp_dir: cwd} do
      id = unique("assigned")

      assert {:ok, %{id: ^id, resumed: false}} =
               Headless.resolve_session(opts(["--session-id", id]), cwd)

      :ok = SessionPersistence.save(id, [%{role: "user", content: "hi"}], cwd)
      assert {:usage, message} = Headless.resolve_session(opts(["--session-id", id]), cwd)
      assert message =~ "--resume"
    end
  end

  describe "session model memory" do
    test "last_model/1 reads what a run recorded", %{tmp_dir: cwd} do
      id = unique("model")
      :ok = SessionPersistence.save(id, [], cwd)
      assert SessionPersistence.last_model(id) == nil
      :ok = SessionPersistence.update_metadata(id, %{provider: "openai", model: "gpt-6"})
      assert SessionPersistence.last_model(id) == {"openai", "gpt-6"}
    end
  end

  describe "--mcp-config" do
    @servers ~s({"mcpServers":{"Docs Server":{"command":"docs-mcp","args":["--stdio"]}}})

    test "inline JSON and files parse; anything else is a usage error", %{tmp_dir: dir} do
      assert {:ok, [server]} = Config.parse_flag_config(@servers)
      assert server.name == "docs_server"
      assert server.source == :flag

      path = Path.join(dir, "mcp.json")
      File.write!(path, @servers)
      assert {:ok, [_]} = Config.parse_flag_config(path)

      assert {:error, message} = Config.parse_flag_config(Path.join(dir, "missing.json"))
      assert message =~ "cannot read"
      assert {:error, _} = Config.parse_flag_config(~s({"servers":{}}))
    end

    test "flag servers join the configured ones, or replace them when strict" do
      on_exit(fn ->
        Application.delete_env(:optimal_system_agent, :mcp_flag_configs)
        Application.delete_env(:optimal_system_agent, :mcp_strict)
      end)

      Application.put_env(:optimal_system_agent, :mcp_flag_configs, [@servers])
      assert "docs_server" in Enum.map(Config.load_startup(), & &1.name)

      Application.put_env(:optimal_system_agent, :mcp_strict, true)
      assert Enum.map(Config.load_startup(), & &1.name) == ["docs_server"]
    end
  end

  test "usage text names the contract flags" do
    usage = Headless.usage()

    for flag <- ~w(--format --resume --overdrive --model --input-format --session-id --continue) do
      assert usage =~ flag
    end

    assert usage =~ "OSA_PRE_TOOL_HOOK"
  end
end
