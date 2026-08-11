defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.VncHardeningTest do
  @moduledoc """
  Port threading and access control for the desktop VNC path.

  No VNC server is started and no real desktop is touched: the controller is
  pointed at a plain `:gen_tcp` listener, and the x11vnc argv is asserted on
  without spawning x11vnc.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{Controller, X11vnc}
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.VncHardeningTest.FakeRouter

  @moduletag :open_computers

  # ── Finding 4: never connect to a port we did not bind ──────────────────────

  describe "resolve_vnc_port/2" do
    test "uses the port the backend reported" do
      assert {:ok, 47_123} =
               Controller.resolve_vnc_port(
                 %{os_pid: 111, vnc_port: 47_123},
                 %{vnc_start_fn: nil, vnc_port_override: nil}
               )
    end

    test "refuses when the backend did not report a port" do
      # The old code ignored the handle entirely and connected to a hardcoded
      # 5900 that x11vnc (started with `-rfbport 0`) never binds — whatever
      # else held 5900 got its framebuffer relayed and remote input injected.
      assert {:error, :vnc_port_unknown} =
               Controller.resolve_vnc_port(
                 %{os_pid: 111},
                 %{vnc_start_fn: nil, vnc_port_override: nil}
               )

      assert {:error, :vnc_port_unknown} =
               Controller.resolve_vnc_port(
                 :fake_vnc_pid,
                 %{vnc_start_fn: nil, vnc_port_override: nil}
               )
    end

    test "never resolves to 5900 by default" do
      assert {:error, :vnc_port_unknown} =
               Controller.resolve_vnc_port(%{}, %{vnc_start_fn: nil, vnc_port_override: nil})
    end

    test "a port override is honoured only alongside the test start hook" do
      state_without_hook = %{vnc_start_fn: nil, vnc_port_override: 5900}
      assert {:error, :vnc_port_unknown} = Controller.resolve_vnc_port(%{}, state_without_hook)

      state_with_hook = %{vnc_start_fn: fn -> {:ok, %{}} end, vnc_port_override: 5900}
      assert {:ok, 5900} = Controller.resolve_vnc_port(%{}, state_with_hook)
    end
  end

  describe "session start" do
    test "connects to the port carried by the backend handle" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_addr, port}} = :inet.sockname(listener)

      {:ok, router} = FakeRouter.start_link()

      {:ok, controller} =
        Controller.start_link(
          name: nil,
          # No vnc_port_override: the port must come from the handle alone.
          vnc_start_fn: fn -> {:ok, %{os_pid: 4242, vnc_port: port, secret: "s3cr3tpw"}} end,
          frame_router_pid: router
        )

      on_exit(fn ->
        if Process.alive?(controller), do: GenServer.stop(controller)
        if Process.alive?(router), do: GenServer.stop(router)
        :gen_tcp.close(listener)
      end)

      session_id = "vnc-#{System.unique_integer([:positive])}"
      accept = Task.async(fn -> :gen_tcp.accept(listener, 2_000) end)

      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id}}})

      assert {:ok, _sock} = Task.await(accept, 3_000)
      assert {:desktop_ready, ready} = FakeRouter.await_frame(router)
      assert ready.session_id == session_id
      # The RFB client is on the far side of the relay; it needs the secret.
      assert ready.vnc_password == "s3cr3tpw"
    end

    test "reports an error instead of connecting when the port is unknown" do
      {:ok, router} = FakeRouter.start_link()

      {:ok, controller} =
        Controller.start_link(
          name: nil,
          vnc_start_fn: fn -> {:ok, :legacy_pid_only} end,
          frame_router_pid: router
        )

      on_exit(fn ->
        if Process.alive?(controller), do: GenServer.stop(controller)
        if Process.alive?(router), do: GenServer.stop(router)
      end)

      session_id = "vnc-#{System.unique_integer([:positive])}"
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id}}})

      assert {:desktop_error, err} = FakeRouter.await_frame(router)
      assert err.reason == :vnc_port_unknown
    end
  end

  # ── Finding 5: unauthenticated, shared, persistent server ──────────────────

  describe "X11vnc.build_args/2" do
    test "requires a password, read from a file so it is not visible in ps" do
      args = X11vnc.build_args(":0", %{secret: "abcd1234", file: "/tmp/osa-vnc-x.pass"})

      assert "-passwdfile" in args
      assert "rm:/tmp/osa-vnc-x.pass" in args
      refute "abcd1234" in args, "the password must never appear in argv"
    end

    test "does not allow unlimited simultaneous viewers" do
      args = X11vnc.build_args(":0", %{secret: "abcd1234", file: "/tmp/p"})
      refute "-shared" in args
    end

    test "does not keep serving the desktop after the viewer leaves" do
      args = X11vnc.build_args(":0", %{secret: "abcd1234", file: "/tmp/p"})
      refute "-forever" in args
    end

    test "stays on loopback with a kernel-assigned port" do
      args = X11vnc.build_args(":0", %{secret: "abcd1234", file: "/tmp/p"})
      assert "-localhost" in args
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-rfbport", "0"])
    end
  end

  describe "X11vnc.make_auth/0" do
    test "writes an owner-only password file and returns the secret" do
      assert {:ok, %{secret: secret, file: file}} = X11vnc.make_auth()
      on_exit(fn -> File.rm(file) end)

      assert byte_size(secret) == 8
      assert File.read!(file) == secret <> "\n"

      {:ok, %File.Stat{mode: mode}} = File.stat(file)
      assert Bitwise.band(mode, 0o077) == 0
    end

    test "secrets differ per session" do
      {:ok, a} = X11vnc.make_auth()
      {:ok, b} = X11vnc.make_auth()
      on_exit(fn -> Enum.each([a.file, b.file], &File.rm/1) end)

      refute a.secret == b.secret
      refute a.file == b.file
    end

    test "disabling auth is explicit and drops the password file" do
      Application.put_env(:optimal_system_agent, :desktop_vnc_auth, false)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :desktop_vnc_auth) end)

      assert {:ok, nil} = X11vnc.make_auth()

      assert X11vnc.build_args(":0", nil) == [
               "-display",
               ":0",
               "-localhost",
               "-rfbport",
               "0",
               "-quiet"
             ]
    end
  end

  # ── Test helper ────────────────────────────────────────────────────────────

  defmodule FakeRouter do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, self())

    def await_frame(pid, timeout \\ 3_000) do
      GenServer.call(pid, :await, timeout)
    end

    @impl true
    def init(_), do: {:ok, %{frames: [], waiting: nil}}

    @impl true
    def handle_cast({:outbound, frame}, %{waiting: nil} = state) do
      {:noreply, %{state | frames: state.frames ++ [frame]}}
    end

    def handle_cast({:outbound, frame}, %{waiting: from} = state) do
      GenServer.reply(from, frame)
      {:noreply, %{state | waiting: nil}}
    end

    @impl true
    def handle_call(:await, from, %{frames: [head | tail]} = state) do
      _ = from
      {:reply, head, %{state | frames: tail}}
    end

    def handle_call(:await, from, state), do: {:noreply, %{state | waiting: from}}
  end
end
