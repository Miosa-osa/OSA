defmodule OptimalSystemAgent.CLI.RemoteTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.CLI.Remote

  describe "parse_exec/1" do
    test "host + command" do
      assert {:ok, %{host: "home", cmd: "uname -a"}} = Remote.parse_exec(["home", "uname", "-a"])
    end

    test "strips a leading -- separator" do
      assert {:ok, %{host: "home", cmd: "echo hi"}} =
               Remote.parse_exec(["home", "--", "echo", "hi"])
    end

    test "missing command is an error" do
      assert {:error, msg} = Remote.parse_exec(["home"])
      assert msg =~ "no command"
    end

    test "no args is an error" do
      assert {:error, _} = Remote.parse_exec([])
    end
  end

  describe "parse_agent/1" do
    test "host + prompt, options stripped out" do
      assert {:ok, %{host: "home", prompt: "fix the failing test", opts: opts}} =
               Remote.parse_agent(["home", "fix", "the", "failing", "test", "--dir", "/work"])

      assert opts[:dir] == "/work"
    end

    test "model + provider options parse" do
      assert {:ok, %{host: "box", prompt: "do it", opts: opts}} =
               Remote.parse_agent([
                 "box",
                 "do",
                 "it",
                 "--model",
                 "glm-4.7",
                 "--provider",
                 "miosa"
               ])

      assert opts[:model] == "glm-4.7"
      assert opts[:provider] == "miosa"
    end

    test "missing prompt is an error" do
      assert {:error, msg} = Remote.parse_agent(["home"])
      assert msg =~ "no prompt"
    end

    test "no args is an error" do
      assert {:error, _} = Remote.parse_agent([])
    end
  end

  describe "parse_kill/1" do
    test "session id only (#484 kill takes just a session id)" do
      assert {:ok, %{session_id: "sid-1"}} = Remote.parse_kill(["sid-1"])
    end

    test "extra args after the session id are ignored" do
      assert {:ok, %{session_id: "sid-1"}} = Remote.parse_kill(["sid-1", "extra"])
    end

    test "no args is an error" do
      assert {:error, _} = Remote.parse_kill([])
    end
  end

  describe "usage + help dispatch" do
    test "usage/0 lists every verb" do
      text = Remote.usage()

      for verb <- ["hosts", "exec", "agent", "sessions", "kill", "shell"] do
        assert text =~ verb
      end
    end

    test "usage/0 mentions the opencomputers:write scope requirement" do
      assert Remote.usage() =~ "opencomputers:write"
    end

    test "dispatch([--help]) prints usage without error" do
      out = ExUnit.CaptureIO.capture_io(fn -> Remote.dispatch(["--help"]) end)
      assert out =~ "Usage: osa remote"
      assert out =~ "hosts"
    end

    test "dispatch([]) prints usage" do
      out = ExUnit.CaptureIO.capture_io(fn -> Remote.dispatch([]) end)
      assert out =~ "Usage: osa remote"
    end
  end

  describe "shell / sessions are gated off (not in the #484 contract)" do
    test "shell_unavailable_message is clear about the release status" do
      msg = Remote.shell_unavailable_message()
      assert msg =~ "not available yet"
      assert msg =~ "exec and agent work"
    end

    test "sessions_unavailable_message explains the per-connection scoping" do
      msg = Remote.sessions_unavailable_message()
      assert msg =~ "not available yet"
    end
  end
end
