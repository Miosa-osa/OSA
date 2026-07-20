defmodule OptimalSystemAgent.Remote.FramesTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Session.FrameCodec
  alias OptimalSystemAgent.Remote.Frames

  # Every frame the client emits must survive the same erlang-term codec the
  # host uses on the wire. These round-trips prove the frames encode/decode
  # cleanly and keep the exact shape the host executors already expect.
  defp roundtrip(term) do
    assert {:ok, ^term} = FrameCodec.decode(FrameCodec.encode(term))
    term
  end

  describe "control-plane frames" do
    test "client_hello carries the account key, version and client role" do
      {:client_hello, payload} = frame = Frames.client_hello("msk_u_abc")
      roundtrip(frame)
      assert payload.account_key == "msk_u_abc"
      assert payload.role == :client
      assert is_binary(payload.version)
    end

    test "hosts_list_request round-trips" do
      assert {:hosts_list_request, %{}} = roundtrip(Frames.hosts_list_request())
    end

    test "session_create_request carries ref/host/kind/params" do
      {:session_create_request, p} =
        frame = Frames.session_create_request("ref1", "home", :shell, %{cols: 80})

      roundtrip(frame)
      assert p.ref == "ref1"
      assert p.host == "home"
      assert p.kind == :shell
      assert p.params == %{cols: 80}
    end

    test "session_kill_request round-trips with and without a host" do
      roundtrip(Frames.session_kill_request("home", "sid-1"))

      assert {:session_kill_request, %{host: nil, session_id: "sid-1"}} =
               roundtrip(Frames.session_kill_request(nil, "sid-1"))
    end
  end

  describe "data-plane job frames (mirror the host executor contract)" do
    test "exec_job uses session_id as job id and kind :exec_on_host" do
      {:job, job} = frame = Frames.exec_job("sid-9", "uname -a", cwd: "/tmp", timeout_ms: 5_000)
      roundtrip(frame)
      assert job.id == "sid-9"
      assert job.kind == :exec_on_host
      assert job.cmd == "uname -a"
      assert job.cwd == "/tmp"
      assert job.timeout_ms == 5_000
    end

    test "exec_job omits optional keys when not given" do
      {:job, job} = Frames.exec_job("sid-9", "ls")
      refute Map.has_key?(job, :cwd)
      refute Map.has_key?(job, :env)
    end

    test "agent_job carries prompt + context and kind :dispatch_agent" do
      {:job, job} =
        frame =
        Frames.agent_job("sid-3", "fix CI", dir: "/work", model: "glm-4.7", provider: "miosa")

      roundtrip(frame)
      assert job.id == "sid-3"
      assert job.kind == :dispatch_agent
      assert job.prompt == "fix CI"
      assert job.context.working_dir == "/work"
      assert job.context.model == "glm-4.7"
      assert job.context.provider == "miosa"
    end
  end

  describe "data-plane pty frames" do
    test "pty_open/input/resize/close all round-trip and key by session_id" do
      {:pty_open_request, open} =
        roundtrip(Frames.pty_open("s1", "/bin/bash", 100, 40, cwd: "/home"))

      assert open.session_id == "s1"
      assert open.shell == "/bin/bash"
      assert open.cols == 100
      assert open.rows == 40
      assert open.cwd == "/home"

      assert {:pty_input, %{session_id: "s1", data: "ls\n"}} =
               roundtrip(Frames.pty_input("s1", "ls\n"))

      assert {:pty_resize, %{session_id: "s1", cols: 120, rows: 50}} =
               roundtrip(Frames.pty_resize("s1", 120, 50))

      assert {:pty_close, %{session_id: "s1", exit_code: 0}} =
               roundtrip(Frames.pty_close("s1"))
    end

    test "pty_open omits shell when nil (host applies its own default)" do
      {:pty_open_request, open} = Frames.pty_open("s2", nil, 80, 24)
      refute Map.has_key?(open, :shell)
    end
  end

  describe "response parsers" do
    test "parse_hosts_list extracts the host list" do
      assert {:ok, [%{id: "h1"}]} =
               Frames.parse_hosts_list({:hosts_list, %{hosts: [%{id: "h1"}]}})

      assert :error = Frames.parse_hosts_list({:something_else, %{}})
    end

    test "parse_session_created requires a session_id" do
      assert {:ok, %{session_id: "s5"}} =
               Frames.parse_session_created({:session_created, %{ref: "r", session_id: "s5"}})

      assert :error = Frames.parse_session_created({:session_created, %{ref: "r"}})
    end

    test "parse_sessions_list extracts sessions" do
      assert {:ok, []} = Frames.parse_sessions_list({:sessions_list, %{host: "h", sessions: []}})
      assert :error = Frames.parse_sessions_list({:nope, %{}})
    end

    test "summarize_job_reply formats exec, agent, and failures" do
      assert {:done, text} =
               Frames.summarize_job_reply(
                 {:job_done, "id", %{exit_code: 0, stdout: "hi", stderr: "", duration_ms: 1}}
               )

      assert text =~ "exit=0"
      assert text =~ "hi"

      assert {:done, "the plan"} =
               Frames.summarize_job_reply(
                 {:job_done, "id", %{result: "the plan", tokens_used: 0}}
               )

      assert {:fail, "boom"} =
               Frames.summarize_job_reply({:job_fail, "id", %{reason: :x, message: "boom"}})

      assert :ignore = Frames.summarize_job_reply({:job_accept, "id", 0})
    end
  end
end
