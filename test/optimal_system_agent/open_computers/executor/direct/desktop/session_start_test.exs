defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.SessionStartTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOS
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.X11vnc
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Windows

  test "Windows launches read-only or explicitly authorized input with validated display" do
    assert {:ok, ["--read-only", "--display", "0"]} = Windows.launch_args(%{})

    assert {:ok, ["--allow-input", "--display", "2"]} =
             Windows.launch_args(%{allow_input: true, display: 2})

    assert {:error, :invalid_display} = Windows.launch_args(%{display: "2"})
  end

  test "X11 helper also defaults to view-only and requires explicit input permission" do
    assert "-viewonly" in X11vnc.build_args(":1", nil)
    refute "-viewonly" in X11vnc.build_args(":1", nil, %{allow_input: true})
  end

  test "macOS launch arguments are read-only unless the adapter receives explicit permission" do
    assert {:ok, ["--read-only", "--display", "0"]} = MacOS.launch_args(%{})

    assert {:ok, ["--allow-input", "--display", "2"]} =
             MacOS.launch_args(%{allow_input: true, display: 2})

    assert {:ok, ["--read-only", "--display", "0"]} = MacOS.launch_args(%{allow_input: "true"})
    assert {:error, :invalid_display} = MacOS.launch_args(%{display: -1})
  end

  test "job payload alone cannot authorize input" do
    assert %{allow_input: false} = Desktop.launch_options(%{allow_input: true}, [])
    assert %{allow_input: false} = Desktop.launch_options(%{}, input_authorized: true)

    assert %{allow_input: true} =
             Desktop.launch_options(%{allow_input: true}, input_authorized: true)

    assert %{allow_input: false} =
             Desktop.launch_options(%{input_authorized: true, allow_input: true}, [])
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "actual job session passes only authorized macOS input flags to the owned helper" do
    keys = ["OSA_DESKTOP_HELPER_OVERRIDE", "OSA_DESKTOP_HELPER_SHA256"]
    previous = Enum.map(keys, &{&1, System.get_env(&1)})
    helper = Path.join(System.tmp_dir!(), "desktop-argv-#{System.unique_integer([:positive])}")

    File.write!(
      helper,
      "#!/bin/sh\ncase \"$*\" in\n'--read-only --display 0') exit 40;;\n'--allow-input --display 0') exit 41;;\n*) exit 42;;\nesac\n"
    )

    File.chmod!(helper, 0o700)
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", helper)

    System.put_env(
      "OSA_DESKTOP_HELPER_SHA256",
      Base.encode16(:crypto.hash(:sha256, File.read!(helper)), case: :lower)
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm!(helper)
    end)

    owner = self()

    for {authorized, expected_status} <- [{false, 40}, {true, 41}] do
      {:ok, pid} =
        Desktop.start_link(
          %{id: "permission", allow_input: true, input_authorized: true},
          fn frame ->
            send(owner, frame)
            :ok
          end,
          os_type: {:unix, :darwin},
          input_authorized: authorized
        )

      monitor = Process.monitor(pid)

      assert_receive {:job_fail, "permission",
                      %{reason: :desktop_start_failed, message: message}},
                     2_000

      assert message == inspect({:helper_exited_early, expected_status})
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    end
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "native job without a display fails before helper or relay startup" do
    keys = ["PATH", "DISPLAY", "WAYLAND_DISPLAY", "XDG_SESSION_TYPE"]
    previous = Enum.map(keys, &{&1, System.get_env(&1)})
    dir = Path.join(System.tmp_dir!(), "desktop-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "x11vnc"), "#!/bin/sh\nexit 17\n")
    File.chmod!(Path.join(dir, "x11vnc"), 0o700)
    Enum.each(keys, &System.delete_env/1)
    System.put_env("PATH", dir)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(dir)
    end)

    owner = self()

    {:ok, pid} =
      Desktop.start_link(
        %{id: "headless"},
        fn frame ->
          send(owner, frame)
          :ok
        end,
        os_type: {:unix, :linux}
      )

    monitor = Process.monitor(pid)
    assert_receive {:job_fail, "headless", %{reason: :missing_display}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end
end
