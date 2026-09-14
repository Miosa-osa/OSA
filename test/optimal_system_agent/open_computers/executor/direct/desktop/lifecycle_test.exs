defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.LifecycleTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{Controller, MacOS, HelperPath}

  @moduletag :macos

  setup do
    previous =
      for key <- ["OSA_DESKTOP_HELPER_OVERRIDE", "OSA_DESKTOP_HELPER_SHA256"],
          do: {key, System.get_env(key)}

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "invalid startup announcement reaps the native subprocess" do
    path = Path.join(System.tmp_dir!(), "osa-bad-helper-#{System.unique_integer([:positive])}")
    # exec preserves the PID so we can check the exact process the adapter owns.
    File.write!(path, "#!/bin/sh\nprintf 'PORT=0\\n'\nexec /bin/sleep 30\n")
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", path)
    System.put_env("OSA_DESKTOP_HELPER_SHA256", HelperPath.sha256_file(path))
    before = MapSet.new(Port.list())
    assert {:error, {:bad_port_value, "0"}} = MacOS.spawn()
    leaked = Enum.reject(Port.list(), &MapSet.member?(before, &1))
    assert leaked == []
  end

  test "failed TCP connection closes the helper Port, even with an os_pid field" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, unused}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    owner = self()

    start = fn ->
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary, :exit_status])
      {:os_pid, pid} = Port.info(port, :os_pid)
      send(owner, {:helper, port})
      {:ok, %{port_ref: port, os_pid: pid, vnc_port: unused}}
    end

    controller =
      start_supervised!({Controller, name: nil, vnc_start_fn: start, frame_router_pid: self()})

    GenServer.cast(controller, {:frame, {:desktop_start_request, %{session_id: "failed"}}})
    assert_receive {:helper, port}
    assert_receive {:"$gen_cast", {:outbound, {:desktop_error, _}}}, 2_000
    assert Port.info(port) == nil
    assert :sys.get_state(controller).sessions == %{}
  end

  test "replacement and controller shutdown close previous sockets" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, number}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    controller =
      start_supervised!(
        {Controller,
         name: nil, vnc_start_fn: fn -> {:ok, %{vnc_port: number}} end, frame_router_pid: self()}
      )

    start = {:frame, {:desktop_start_request, %{session_id: "same"}}}
    GenServer.cast(controller, start)
    {:ok, first} = :gen_tcp.accept(listener, 2_000)
    assert_receive {:"$gen_cast", {:outbound, {:desktop_ready, _}}}
    GenServer.cast(controller, start)
    {:ok, second} = :gen_tcp.accept(listener, 2_000)
    assert_receive {:"$gen_cast", {:outbound, {:desktop_ready, _}}}
    assert {:error, :closed} = :gen_tcp.recv(first, 0, 2_000)
    GenServer.stop(controller)
    assert {:error, :closed} = :gen_tcp.recv(second, 0, 2_000)
  end

  @tag :macos_native
  test "a refused relay connection reaps the real native helper" do
    helper = Path.join(:code.priv_dir(:optimal_system_agent), "helpers/osa-screen-capture-darwin")

    wrapper =
      Path.join(System.tmp_dir!(), "osa-stub-helper-#{System.unique_integer([:positive])}")

    # Use the actual subprocess and adapter, but never request screen access.
    quoted = "'" <> String.replace(helper, "'", "'\\''") <> "'"
    File.write!(wrapper, "#!/bin/sh\nexec #{quoted} --stub\n")
    File.chmod!(wrapper, 0o700)
    on_exit(fn -> File.rm(wrapper) end)
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", wrapper)
    System.put_env("OSA_DESKTOP_HELPER_SHA256", HelperPath.sha256_file(wrapper))

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    parent = self()
    before = MapSet.new(Port.list())

    {:ok, desktop} =
      OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.start_link(
        %{id: "refused", relay_url: "ws://127.0.0.1:#{port}/"},
        fn result ->
          send(parent, result)
          :ok
        end
      )

    monitor = Process.monitor(desktop)
    assert_receive {:job_fail, "refused", %{reason: :ws_connect_failed}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^desktop, :normal}, 2_000
    assert Enum.reject(Port.list(), &MapSet.member?(before, &1)) == []
  end
end
