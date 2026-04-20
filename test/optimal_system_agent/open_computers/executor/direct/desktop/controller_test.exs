defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.ControllerTest do
  @moduledoc """
  Unit tests for `Desktop.Controller`.

  The controller is started with `name: nil` so it does not conflict with the
  globally-registered instance started by the application supervision tree.

  Outbound frames are captured via a `FakeRouter` GenServer passed as
  `frame_router_pid` — this avoids hijacking the global `FrameRouter` name
  and makes tests safe to run alongside the real supervisor.

  A fake TCP VNC server (an ephemeral `:gen_tcp.listen` socket) stands in for
  the real x11vnc. The `vnc_start_fn` opt bypasses OS detection and the 500ms
  startup sleep, so tests stay fast.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.X11vnc

  @moduletag :open_computers

  setup do
    {:ok, fake_vnc_listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(fake_vnc_listen)

    {:ok, fake_router} = start_fake_router()

    {:ok, controller} =
      Controller.start_link(
        name: nil,
        vnc_port_override: port,
        vnc_start_fn: fn -> {:ok, :fake_vnc_pid} end,
        frame_router_pid: fake_router
      )

    on_exit(fn ->
      if Process.alive?(controller), do: GenServer.stop(controller)
      if Process.alive?(fake_router), do: GenServer.stop(fake_router)
      :gen_tcp.close(fake_vnc_listen)
    end)

    {:ok,
     controller: controller,
     fake_vnc_listen: fake_vnc_listen,
     fake_router: fake_router,
     vnc_port: port}
  end

  describe "desktop_start_request" do
    test "starts VNC and sends desktop_ready frame", %{
      controller: controller,
      fake_vnc_listen: listen_sock
    } do
      session_id = Ecto.UUID.generate()
      accept_task = start_accepting(listen_sock)
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1920, height: 1080}}})
      vnc_peer = Task.await(accept_task, 5_000)

      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id, capabilities: _caps}}}, 3_000

      %{sessions: sessions} = :sys.get_state(controller)
      assert Map.has_key?(sessions, session_id)
      :gen_tcp.close(vnc_peer)
    end
  end

  describe "downstream data flow" do
    test "bytes from VNC socket are wrapped and sent to FrameRouter", %{
      controller: controller,
      fake_vnc_listen: listen_sock
    } do
      session_id = Ecto.UUID.generate()
      accept_task = start_accepting(listen_sock)
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1280, height: 720}}})
      vnc_peer = Task.await(accept_task, 5_000)

      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id}}}, 3_000

      test_data = :crypto.strong_rand_bytes(128)
      :ok = :gen_tcp.send(vnc_peer, test_data)

      assert_receive {:outbound_frame,
                      {:desktop_data,
                       %{session_id: ^session_id, direction: :downstream, data: ^test_data}}},
                     3_000

      :gen_tcp.close(vnc_peer)
    end
  end

  describe "upstream data flow" do
    test "desktop_data upstream frame is written to VNC socket", %{
      controller: controller,
      fake_vnc_listen: listen_sock
    } do
      session_id = Ecto.UUID.generate()
      accept_task = start_accepting(listen_sock)
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1280, height: 720}}})
      vnc_peer = Task.await(accept_task, 5_000)

      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id}}}, 3_000

      upstream_data = :crypto.strong_rand_bytes(64)

      GenServer.cast(controller, {:frame,
        {:desktop_data,
         %{session_id: session_id, direction: :upstream, data: upstream_data}}})

      {:ok, received} = :gen_tcp.recv(vnc_peer, byte_size(upstream_data), 2_000)
      assert received == upstream_data
      :gen_tcp.close(vnc_peer)
    end
  end

  describe "desktop_stop" do
    test "closes VNC socket and removes session", %{
      controller: controller,
      fake_vnc_listen: listen_sock
    } do
      session_id = Ecto.UUID.generate()
      accept_task = start_accepting(listen_sock)
      GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: session_id, width: 1280, height: 720}}})
      _vnc_peer = Task.await(accept_task, 5_000)

      assert_receive {:outbound_frame, {:desktop_ready, %{session_id: ^session_id}}}, 3_000

      GenServer.cast(controller, {:frame, {:desktop_stop, %{session_id: session_id}}})
      Process.sleep(50)

      %{sessions: sessions} = :sys.get_state(controller)
      refute Map.has_key?(sessions, session_id)
    end
  end

  describe "X11vnc.start/1" do
    test "returns :unsupported_platform when binary does not exist" do
      assert {:error, :unsupported_platform} =
               X11vnc.start(%{binary: "/nonexistent/x11vnc"})
    end
  end

  defp start_accepting(listen_sock) do
    test_pid = self()

    Task.async(fn ->
      {:ok, sock} = :gen_tcp.accept(listen_sock, 5_000)
      :gen_tcp.controlling_process(sock, test_pid)
      sock
    end)
  end

  defp start_fake_router do
    test_pid = self()
    GenServer.start_link(__MODULE__.FakeRouter, %{test_pid: test_pid})
  end

  defmodule FakeRouter do
    use GenServer
    def init(%{test_pid: test_pid}), do: {:ok, %{test_pid: test_pid}}
    def handle_cast({:outbound, frame}, state) do
      send(state.test_pid, {:outbound_frame, frame})
      {:noreply, state}
    end
    def handle_cast(_msg, state), do: {:noreply, state}
    def handle_info(_msg, state), do: {:noreply, state}
  end
end
