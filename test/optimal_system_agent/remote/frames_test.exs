defmodule OptimalSystemAgent.Remote.FramesTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Session.FrameCodec
  alias OptimalSystemAgent.Remote.Frames

  # Every wrapped message the client emits must survive the same erlang-term
  # codec the host uses on the wire.
  defp roundtrip(term) do
    assert {:ok, ^term} = FrameCodec.decode(FrameCodec.encode(term))
    term
  end

  describe "envelope wrap/unwrap" do
    test "wrap produces the v:1 oc_remote envelope with a request_id and round-trips" do
      body = {:remote_hosts_list, %{}}
      {:oc_remote, env} = wrapped = Frames.wrap(body)

      assert env.v == 1
      assert is_binary(env.request_id)
      assert env.body == body

      roundtrip(wrapped)
      assert {:ok, ^body} = Frames.unwrap(wrapped)
    end

    test "wrap generates a fresh request_id per message" do
      {:oc_remote, %{request_id: r1}} = Frames.wrap({:remote_hosts_list, %{}})
      {:oc_remote, %{request_id: r2}} = Frames.wrap({:remote_hosts_list, %{}})
      refute r1 == r2
    end

    test "request_id looks like a uuid" do
      assert Frames.request_id() =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "unwrap rejects a non-envelope or wrong version" do
      assert :error = Frames.unwrap({:remote_hosts_list, %{}})
      assert :error = Frames.unwrap({:oc_remote, %{v: 2, request_id: "x", body: :nope}})
      assert :error = Frames.unwrap({:oc_remote, %{v: 1, request_id: 123, body: :nope}})
    end
  end

  describe "client -> server bodies" do
    test "remote_hello carries account_key and client_instance_id" do
      {:remote_hello, p} = frame = Frames.remote_hello("msk_u_abc", "osa-inst-1")
      roundtrip(Frames.wrap(frame))
      assert p.account_key == "msk_u_abc"
      assert p.client_instance_id == "osa-inst-1"
    end

    test "remote_hosts_list round-trips" do
      assert {:remote_hosts_list, %{}} = frame = Frames.remote_hosts_list()
      roundtrip(Frames.wrap(frame))
    end

    test "remote_session_open (exec) carries ref/host_id/kind/params" do
      params = Frames.exec_params("uname -a")

      {:remote_session_open, p} =
        frame = Frames.remote_session_open("ref1", "host-9", :exec, params)

      roundtrip(Frames.wrap(frame))
      assert p.ref == "ref1"
      assert p.host_id == "host-9"
      assert p.kind == :exec
      assert p.params == %{cmd: "uname -a"}
    end

    test "remote_session_open (agent) carries agent params" do
      params = Frames.agent_params("fix CI", dir: "/work", model: "glm-4.7", provider: "miosa")

      {:remote_session_open, p} =
        frame = Frames.remote_session_open("ref2", "host-9", :agent, params)

      roundtrip(Frames.wrap(frame))
      assert p.kind == :agent
      assert p.params.prompt == "fix CI"
      assert p.params.context == %{cwd: "/work", model: "glm-4.7", provider: "miosa"}
    end

    test "remote_session_close carries session_id" do
      assert {:remote_session_close, %{session_id: "sid-1"}} =
               frame = Frames.remote_session_close("sid-1")

      roundtrip(Frames.wrap(frame))
    end

    test "pong echoes the ping sequence" do
      assert {:pong, 7} = frame = Frames.pong(7)
      roundtrip(Frames.wrap(frame))
    end
  end

  describe "exec_params/2" do
    test "cmd only omits every optional key" do
      p = Frames.exec_params("ls")
      assert p == %{cmd: "ls"}
    end

    test "carries args/cwd/env/timeout_ms when supplied" do
      p =
        Frames.exec_params("grep",
          args: ["-r", "foo"],
          cwd: "/tmp",
          env: [{"FOO", "bar"}],
          timeout_ms: 5_000
        )

      assert p.cmd == "grep"
      assert p.args == ["-r", "foo"]
      assert p.cwd == "/tmp"
      assert p.env == [{"FOO", "bar"}]
      assert p.timeout_ms == 5_000
    end
  end

  describe "agent_params/2" do
    test "prompt only has no context key" do
      p = Frames.agent_params("do it")
      assert p == %{prompt: "do it"}
      refute Map.has_key?(p, :context)
    end

    test "only the allowed context keys are populated; :dir maps to :cwd" do
      p = Frames.agent_params("do it", dir: "/w", model: "m", provider: "pr", timeout_ms: 9_000)
      assert p.prompt == "do it"
      assert p.context == %{cwd: "/w", model: "m", provider: "pr"}
      assert p.timeout_ms == 9_000
    end
  end

  describe "server -> client parsers" do
    test "parse_hosts extracts the host list" do
      assert {:ok, [%{id: "h1", name: "home", online: true, os_kind: :linux}]} =
               Frames.parse_hosts(
                 {:remote_hosts,
                  %{hosts: [%{id: "h1", name: "home", online: true, os_kind: :linux}]}}
               )

      assert :error = Frames.parse_hosts({:something_else, %{}})
    end

    test "parse_session_opened requires a session_id" do
      assert {:ok, "s5"} =
               Frames.parse_session_opened(
                 {:remote_session_opened, %{ref: "r", session_id: "s5"}}
               )

      assert :error = Frames.parse_session_opened({:remote_session_opened, %{ref: "r"}})
    end

    test "parse_session_closed extracts session_id + reason" do
      assert {:ok, %{session_id: "s1", reason: :client_closed}} =
               Frames.parse_session_closed(
                 {:remote_session_closed, %{session_id: "s1", reason: :client_closed}}
               )

      assert :error = Frames.parse_session_closed({:nope, %{}})
    end

    test "parse_error extracts the reason and optional ref" do
      assert {:ok, %{reason: :forbidden}} =
               Frames.parse_error({:remote_error, %{reason: :forbidden}})

      assert {:ok, %{ref: "r", reason: :host_offline}} =
               Frames.parse_error({:remote_error, %{ref: "r", reason: :host_offline}})

      assert :error = Frames.parse_error({:remote_error, %{}})
    end
  end

  describe "remote_session_frame handling" do
    test "unwrap_session_frame extracts the inner host frame by session_id" do
      inner = {:job_done, "sid-1", %{exit_code: 0, stdout: "hi"}}

      assert {:ok, "sid-1", ^inner} =
               Frames.unwrap_session_frame(
                 {:remote_session_frame, %{session_id: "sid-1", frame: inner}}
               )

      assert :error = Frames.unwrap_session_frame({:remote_hosts, %{}})
    end

    test "render_session_frame formats exec, agent, chunk, and failure inner frames" do
      assert {:done, text} =
               Frames.render_session_frame(
                 {:job_done, "sid", %{exit_code: 0, stdout: "hi", stderr: ""}}
               )

      assert text =~ "exit=0"
      assert text =~ "hi"

      assert {:done, "the plan"} =
               Frames.render_session_frame({:job_done, "sid", %{result: "the plan"}})

      assert {:done, exec_text} =
               Frames.render_session_frame({:exec_result, %{exit_code: 2, stdout: "out"}})

      assert exec_text =~ "exit=2"

      assert {:chunk, "streamed"} =
               Frames.render_session_frame({:exec_chunk, %{data: "streamed", stream: :stdout}})

      assert {:fail, "boom"} =
               Frames.render_session_frame({:job_fail, "sid", %{message: "boom"}})

      assert {:fail, "host_offline"} =
               Frames.render_session_frame({:job_fail, "sid", :host_offline})

      assert :ignore = Frames.render_session_frame({:job_accept, "sid", 0})
    end

    test "terminal_inner_frame? recognizes terminal host frames only" do
      assert Frames.terminal_inner_frame?({:job_done, "s", %{}})
      assert Frames.terminal_inner_frame?({:job_fail, "s", :x})
      assert Frames.terminal_inner_frame?({:exec_result, %{}})
      refute Frames.terminal_inner_frame?({:exec_chunk, %{data: "x"}})
    end
  end
end
