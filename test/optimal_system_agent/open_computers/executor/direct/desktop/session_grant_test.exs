defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.SessionGrantTest do
  use ExUnit.Case, async: false
  alias OptimalSystemAgent.OpenComputers.Session.FrameRouter
  alias OptimalSystemAgent.OpenComputers.Executor.Supervisor, as: ExecSup
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.SessionGrant
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller

  setup do
    start_supervised!(ExecSup)
    names = ["OSA_DESKTOP_HELPER_OVERRIDE", "OSA_DESKTOP_HELPER_SHA256"]
    saved = Map.new(names, &{&1, System.get_env(&1)})
    path = Path.join(System.tmp_dir!(), "desktop-grant-#{System.unique_integer([:positive])}")

    File.write!(
      path,
      "#!/bin/sh\ncase \"$*\" in\n'--allow-input --display 0') exit 41;;\n'--read-only --display 0') exit 40;;\n*) exit 42;;\nesac\n"
    )

    File.chmod!(path, 0o700)
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", path)

    System.put_env(
      "OSA_DESKTOP_HELPER_SHA256",
      Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
    )

    on_exit(fn ->
      File.rm(path)

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  test "real session controller passes resolved permission and closes TCP when connection grant is cleared" do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Controller,
       [
         frame_router_pid: owner,
         vnc_start_fn: fn opts ->
           send(owner, {:launched, opts})
           {:ok, %{vnc_port: port}}
         end
       ]}
    )

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      send(owner, {:viewer_closed, :gen_tcp.recv(socket, 0, 4_000)})
    end)

    state = %{phase: :active, verified_control: true, host_id: "host", owner_tenant_id: "owner"}

    grant = %{
      session_id: "controller",
      host_id: "host",
      tenant_id: "owner",
      scope: ["desktop:stream", "desktop:control"],
      expires_at: System.system_time(:second) + 60
    }

    {_, state} = FrameRouter.handle({:desktop_session_grant, grant}, state)

    {_, state} =
      FrameRouter.handle(
        {:desktop_start_request,
         %{session_id: "controller", tenant_id: "owner", allow_input: true}},
        state
      )

    assert_receive {:launched, %{allow_input: true}}, 2_000

    assert_receive {:"$gen_cast",
                    {:outbound, {:desktop_ready, %{capabilities: %{keyboard: true}}}}},
                   2_000

    SessionGrant.clear(state)
    assert_receive {:viewer_closed, {:error, :closed}}, 2_000
  end

  test "foreign, expired, insecure and replayed grants cannot authorize input" do
    state = %{phase: :active, verified_control: true, host_id: "host", owner_tenant_id: "owner"}

    grant = %{
      session_id: "session",
      host_id: "host",
      tenant_id: "owner",
      scope: ["desktop:stream", "desktop:control"],
      expires_at: System.system_time(:second) + 60
    }

    request = %{session_id: "session", tenant_id: "owner"}

    for invalid <- [
          Map.put(grant, :host_id, "foreign"),
          Map.put(grant, :tenant_id, "assigned"),
          Map.put(grant, :expires_at, 0),
          Map.put(grant, :expires_at, System.system_time(:second) + 301)
        ] do
      assert {[], _} = SessionGrant.consume(request, SessionGrant.accept(invalid, state))
    end

    assert {[], _} =
             SessionGrant.consume(
               request,
               SessionGrant.accept(grant, %{state | verified_control: false})
             )

    {context, consumed} = SessionGrant.consume(request, SessionGrant.accept(grant, state))
    assert context[:input_authorized]
    assert {[], _} = SessionGrant.consume(request, SessionGrant.accept(grant, consumed))
    lease = context[:desktop_lease]
    ref = Process.monitor(lease)
    SessionGrant.clear(consumed)
    assert_receive {:DOWN, ^ref, :process, ^lease, :normal}
  end

  @tag skip: :os.type() != {:unix, :darwin}
  test "actual inbound job consumes matching control grant once; payload flags cannot grant input" do
    state = %{phase: :active, verified_control: true, host_id: "host", owner_tenant_id: "owner"}

    grant = %{
      session_id: "session",
      host_id: "host",
      tenant_id: "owner",
      scope: ["desktop:stream", "desktop:control"],
      expires_at: System.system_time(:second) + 60
    }

    job = %{
      id: "job",
      kind: :stream_native_desktop,
      session_id: "session",
      tenant_id: "owner",
      allow_input: true,
      input_authorized: true
    }

    {_, state} = FrameRouter.handle({:job, job}, state)

    assert_receive {:executor_frame,
                    {:job_fail, "job", %{message: "{:helper_exited_early, 40}"}}},
                   2_000

    {_, state} = FrameRouter.handle({:desktop_session_grant, grant}, state)
    {_, state} = FrameRouter.handle({:job, job}, state)

    assert_receive {:executor_frame,
                    {:job_fail, "job", %{message: "{:helper_exited_early, 41}"}}},
                   2_000

    FrameRouter.handle({:job, job}, state)

    assert_receive {:executor_frame,
                    {:job_fail, "job", %{message: "{:helper_exited_early, 40}"}}},
                   2_000
  end
end
