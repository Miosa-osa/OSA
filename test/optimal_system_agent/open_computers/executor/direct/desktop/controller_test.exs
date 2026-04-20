defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.ControllerTest do
  @moduledoc """
  Unit tests for `Desktop.Controller`.

  Uses a fake x11vnc binary (the `cat` command) so tests run without an
  actual X11 display or x11vnc installation. `cat` inherits stdin/stdout
  and exits when its stdin is closed — sufficient to test the TCP lifecycle.

  The test starts a real TCP server on an ephemeral port and configures
  the controller to connect to it instead of :5900. A fake FrameRouter
  is injected so we can assert on outbound frames without a real WS connection.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.X11vnc

  @moduletag :open_computers

  setup do
    # Disable the real OpenComputers supervisor (Extensions) in tests
    Application.put_env(:optimal_system_agent, :open_computers_enabled, false)
    on_exit(fn -> Application.put_env(:optimal_system_agent, :open_computers_enabled, true) end)

    # Start a fake VNC server (TCP echo server on ephemeral port)
    {:ok, fake_vnc_listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(fake_vnc_listen)

    # Fake FrameRouter — captures outbound frames for assertion
    {:ok, fake_router} = start_fake_router()

    # Start the controller with patched VNC port + fake binary
    {:ok, controller} =
      Controller.start_link(
        name: nil,
        # Override VNC connection target in the controller
        vnc_port_override: port,
        # Provide a fake x11vnc binary (any executable works; we patch start_session)
        vnc_binary: System.find_executable("cat") || "/bin/cat"
      )

    on_exit(fn ->
      if Process.alive?(controller), do: GenServer.stop(controller)
      :gen_tcp.close(fake_vnc_listen)
    end)

    {:ok,
     controller: controller,
     fake_vnc_listen: fake_vnc_listen,
     fake_router: fake_router,
     vnc_port: port}
  end

  # ── desktop_start_request ─────────────────────────────────────────────────────

  describe "desktop_start_request" do
    test "starts VNC and sends desktop_ready frame", %{
      controller: controller,
      fake_vnc_listen: listen_sock,
      fake_router: router
    } do
      session_id = UUID.uuid4()

      # Stub the start_vnc path — instead of spawning x11vnc, inject a fake
      # OS pid by sending the frame with an already-listening VNC port.
      # Accept the connection that the controller will make.
      accept_task = Task.async(fn -> :gen_tcp.accept(listen_sock, 5_000) end)

      # Inject the frame; controller will try to connect to fake VNC port
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1920, height: 1080}}})

      # Accept the connection from controller
      assert {:ok, _socket} = Task.await(accept_task, 5_000)

      # Controller should have sent desktop_ready via FrameRouter
      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id, capabilities: _caps}}, 3_000}

      # Session should now exist in the controller state
      %{sessions: sessions} = :sys.get_state(controller)
      assert Map.has_key?(sessions, session_id)
    end
  end

  # ── downstream data (VNC → control plane) ────────────────────────────────────

  describe "downstream data flow" do
    test "bytes from VNC socket are wrapped and sent to FrameRouter", %{
      controller: controller,
      fake_vnc_listen: listen_sock,
      fake_router: _router
    } do
      session_id = UUID.uuid4()

      accept_task = Task.async(fn -> :gen_tcp.accept(listen_sock, 5_000) end)
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1280, height: 720}}})
      {:ok, vnc_peer} = Task.await(accept_task, 5_000)

      # Wait for desktop_ready
      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id}}, 3_000}

      # Send bytes from VNC side → controller should relay downstream
      test_data = :crypto.strong_rand_bytes(128)
      :gen_tcp.send(vnc_peer, test_data)

      assert_receive {:outbound_frame,
                      {:desktop_data,
                       %{session_id: ^session_id, direction: :downstream, data: ^test_data}},
                      3_000}
    end
  end

  # ── upstream data (control plane → VNC) ──────────────────────────────────────

  describe "upstream data flow" do
    test "desktop_data upstream frame is written to VNC socket", %{
      controller: controller,
      fake_vnc_listen: listen_sock
    } do
      session_id = UUID.uuid4()

      accept_task = Task.async(fn -> :gen_tcp.accept(listen_sock, 5_000) end)
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1280, height: 720}}})
      {:ok, vnc_peer} = Task.await(accept_task, 5_000)

      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id}}, 3_000}

      # Send upstream data → controller should write to VNC socket
      upstream_data = :crypto.strong_rand_bytes(64)

      GenServer.cast(controller, {:frame,
        {:desktop_data,
         %{session_id: session_id, direction: :upstream, data: upstream_data}}})

      # Read from fake VNC peer
      {:ok, received} = :gen_tcp.recv(vnc_peer, byte_size(upstream_data), 2_000)
      assert received == upstream_data
    end
  end

  # ── desktop_stop ──────────────────────────────────────────────────────────────

  describe "desktop_stop" do
    test "closes VNC socket and removes session", %{
      controller: controller,
      fake_vnc_listen: listen_sock
    } do
      session_id = UUID.uuid4()

      accept_task = Task.async(fn -> :gen_tcp.accept(listen_sock, 5_000) end)
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1280, height: 720}}})
      {:ok, _vnc_peer} = Task.await(accept_task, 5_000)

      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id}}, 3_000}

      # Send stop
      GenServer.cast(controller, {:frame, {:desktop_stop, %{session_id: session_id}}})

      # Give it a tick to process
      :timer.sleep(50)

      %{sessions: sessions} = :sys.get_state(controller)
      refute Map.has_key?(sessions, session_id)
    end
  end

  # ── x11vnc binary guard ───────────────────────────────────────────────────────

  describe "X11vnc.start/1" do
    test "returns :unsupported_platform when binary does not exist" do
      assert {:error, :unsupported_platform} =
               X11vnc.start(%{binary: "/nonexistent/x11vnc"})
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp start_fake_router do
    test_pid = self()

    GenServer.start_link(
      __MODULE__.FakeRouter,
      %{test_pid: test_pid},
      name: OptimalSystemAgent.OpenComputers.FrameRouter
    )
  end

  defmodule FakeRouter do
    @moduledoc "Captures outbound send_frame calls and relays them to the test process."
    use GenServer

    def init(%{test_pid: test_pid}), do: {:ok, %{test_pid: test_pid}}

    # Mirrors FrameRouter.send_frame/1 — called by Controller via GenServer.cast
    def handle_cast({:outbound, frame}, state) do
      send(state.test_pid, {:outbound_frame, frame})
      {:noreply, state}
    end

    def handle_call({:register_host_client, _pid}, _from, state), do: {:reply, :ok, state}
    def handle_cast(_msg, state), do: {:noreply, state}
    def handle_info(_msg, state), do: {:noreply, state}
  end
end
