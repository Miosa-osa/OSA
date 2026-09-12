defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.ReadinessTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.{Readiness, X11vnc}
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.HelperProbe

  setup do
    keys = [
      "PATH",
      "DISPLAY",
      "WAYLAND_DISPLAY",
      "XDG_SESSION_TYPE",
      "XDG_RUNTIME_DIR",
      "DBUS_SESSION_BUS_ADDRESS",
      "OSA_DESKTOP_HELPER_OVERRIDE",
      "OSA_DESKTOP_HELPER_SHA256"
    ]

    previous = Enum.map(keys, &{&1, System.get_env(&1)})

    dir =
      Path.join(System.tmp_dir!(), "osa-desktop-readiness-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    Enum.each(keys -- ["PATH"], &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "native desktop start never guesses display :0 on a headless host", %{dir: dir} do
    helper = Path.join(dir, "x11vnc")
    File.write!(helper, "#!/bin/sh\nexit 17\n")
    File.chmod!(helper, 0o700)
    System.put_env("PATH", dir)

    assert {:error, {:missing_display, _}} = X11vnc.start()
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "Linux prerequisites never imply verified screen capture or control", %{dir: dir} do
    helper = Path.join(dir, "x11vnc")
    # An executable that must never be run during a readiness inventory.
    File.write!(helper, "#!/bin/sh\nexit 17\n")
    File.chmod!(helper, 0o700)
    System.put_env("PATH", dir)
    System.put_env("DISPLAY", ":77")

    assert %{
             status: :unverified,
             backend: :x11vnc,
             scope: :physical_desktop,
             capture: :unverified,
             control: :unverified,
             display: ":77",
             helper: ^helper
           } = Readiness.check({:unix, :linux})
  end

  test "a trusted macOS helper does not prove recording or Accessibility permission", %{dir: dir} do
    helper = Path.join(dir, "native-helper.exe")
    File.write!(helper, "#!/bin/sh\nexit 17\n")
    File.chmod!(helper, 0o700)
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", helper)

    System.put_env(
      "OSA_DESKTOP_HELPER_SHA256",
      Base.encode16(:crypto.hash(:sha256, File.read!(helper)), case: :lower)
    )

    assert %{
             backend: :macos,
             status: :unverified,
             capture: :unverified,
             control: :unverified,
             helper: ^helper
           } =
             Readiness.check({:unix, :darwin})
  end

  test "Windows without a helper cannot claim physical desktop support", %{dir: dir} do
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", Path.join(dir, "missing.exe"))
    System.put_env("OSA_DESKTOP_HELPER_SHA256", String.duplicate("0", 64))

    assert %{backend: :windows, status: :unavailable, reason: {:untrusted_helper, _}} =
             Readiness.check({:win32, :nt})
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "XWayland display is not treated as access to the physical Wayland desktop", %{dir: dir} do
    helper = Path.join(dir, "x11vnc")
    File.write!(helper, "#!/bin/sh\nexit 17\n")
    File.chmod!(helper, 0o700)
    System.put_env("PATH", dir)
    System.put_env("WAYLAND_DISPLAY", "wayland-0")
    System.put_env("DISPLAY", ":77")

    assert %{status: :unavailable, reason: {:unsupported_display, _}} =
             Readiness.check({:unix, :linux})

    assert {:error, {:unsupported_display, _}} = X11vnc.start()
  end

  test "unknown operating systems fail closed" do
    assert %{status: :unavailable, reason: :unsupported_platform} =
             Readiness.check({:unix, :freebsd})
  end

  test "Linux without x11vnc reports the missing prerequisite", %{dir: dir} do
    System.put_env("PATH", dir)
    System.put_env("DISPLAY", ":77")
    assert %{status: :unavailable, reason: :missing_binary} = Readiness.check({:unix, :linux})
  end

  test "display selection preserves explicit choice and rejects blank values" do
    System.put_env("DISPLAY", ":77")
    assert {:ok, ":77"} = Readiness.display()
    assert {:ok, ":88"} = Readiness.display(":88")
    assert {:error, {:missing_display, _}} = Readiness.display("  ")
    System.put_env("DISPLAY", "  ")
    assert {:error, {:missing_display, _}} = Readiness.display()
  end

  test "Wayland session type alone also fails closed" do
    System.put_env("XDG_SESSION_TYPE", "wayland")
    System.put_env("DISPLAY", ":77")
    assert {:error, {:unsupported_display, _}} = Readiness.display()
  end

  test "backend selection distinguishes Wayland from XWayland DISPLAY" do
    assert :x11vnc = Readiness.backend({:unix, :linux})
    System.put_env("WAYLAND_DISPLAY", "wayland-0")
    System.put_env("DISPLAY", ":77")
    assert :wayland = Readiness.backend({:unix, :linux})
    assert :macos = Readiness.backend({:unix, :darwin})
    assert :windows = Readiness.backend({:win32, :nt})
    assert :unsupported = Readiness.backend({:unix, :freebsd})
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "Wayland readiness uses only the trusted non-capture check contract", %{dir: dir} do
    helper = Path.join(dir, "portal-helper")

    File.write!(
      helper,
      "#!/bin/sh\n[ \"$1\" = --check ] || exit 17\nprintf 'READY=wayland_portal\\n'\n"
    )

    File.chmod!(helper, 0o700)
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", helper)

    System.put_env(
      "OSA_DESKTOP_HELPER_SHA256",
      Base.encode16(:crypto.hash(:sha256, File.read!(helper)), case: :lower)
    )

    System.put_env("WAYLAND_DISPLAY", "wayland-fixture")
    System.put_env("XDG_RUNTIME_DIR", dir)
    System.put_env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/fixture-only")

    assert %{backend: :wayland, status: :unverified, reason: :live_probe_required} =
             Readiness.check({:unix, :linux})
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "a stalled prerequisite probe is bounded and closes its owned Port", %{dir: dir} do
    helper = Path.join(dir, "stalled-check")
    File.write!(helper, "#!/bin/sh\nexec /bin/sleep 30\n")
    File.chmod!(helper, 0o700)
    ports = MapSet.new(Port.list())
    assert {:error, :helper_check_timeout} = HelperProbe.check(helper, "READY=wayland_portal", 30)
    assert Enum.reject(Port.list(), &MapSet.member?(ports, &1)) == []
  end
end
