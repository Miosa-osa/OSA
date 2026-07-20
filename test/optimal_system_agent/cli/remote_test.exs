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
    test "host + task, options stripped out" do
      assert {:ok, %{host: "home", task: "fix the failing test", opts: opts}} =
               Remote.parse_agent(["home", "fix", "the", "failing", "test", "--dir", "/work"])

      assert opts[:dir] == "/work"
    end

    test "model + provider options parse" do
      assert {:ok, %{host: "box", task: "do it", opts: opts}} =
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

    test "missing task is an error" do
      assert {:error, msg} = Remote.parse_agent(["home"])
      assert msg =~ "no task"
    end

    test "no args is an error" do
      assert {:error, _} = Remote.parse_agent([])
    end
  end

  describe "parse_shell/1" do
    test "host only" do
      assert {:ok, %{host: "home", shell: nil}} = Remote.parse_shell(["home"])
    end

    test "host + --shell" do
      assert {:ok, %{host: "home", shell: "/bin/zsh"}} =
               Remote.parse_shell(["home", "--shell", "/bin/zsh"])
    end

    test "missing host is an error" do
      assert {:error, _} = Remote.parse_shell([])
    end
  end

  describe "parse_sessions/1" do
    test "host required" do
      assert {:ok, %{host: "home"}} = Remote.parse_sessions(["home"])
      assert {:error, _} = Remote.parse_sessions([])
    end
  end

  describe "parse_kill/1" do
    test "host + session id" do
      assert {:ok, %{host: "home", session_id: "sid-1"}} = Remote.parse_kill(["home", "sid-1"])
    end

    test "session id only (broker resolves host)" do
      assert {:ok, %{host: nil, session_id: "sid-1"}} = Remote.parse_kill(["sid-1"])
    end

    test "no args is an error" do
      assert {:error, _} = Remote.parse_kill([])
    end
  end

  describe "usage + help dispatch" do
    test "usage/0 lists every verb" do
      text = Remote.usage()

      for verb <- ["hosts", "exec", "agent", "shell", "sessions", "kill"] do
        assert text =~ verb
      end
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
end
