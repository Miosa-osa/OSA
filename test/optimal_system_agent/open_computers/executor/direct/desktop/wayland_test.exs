defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.WaylandTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Wayland

  setup do
    names = [
      "WAYLAND_DISPLAY",
      "XDG_RUNTIME_DIR",
      "DBUS_SESSION_BUS_ADDRESS",
      "OSA_DESKTOP_HELPER_OVERRIDE",
      "OSA_DESKTOP_HELPER_SHA256"
    ]

    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "absent Wayland session fails without starting a helper" do
    previous = System.get_env("WAYLAND_DISPLAY")
    System.delete_env("WAYLAND_DISPLAY")

    on_exit(fn ->
      if previous, do: System.put_env("WAYLAND_DISPLAY", previous)
    end)

    assert {:error, :wayland_session_unavailable} = Wayland.start()
  end

  test "spawn passes explicit read-only permission by default" do
    helper("[ \"$*\" = '--read-only' ] || exit 64; printf 'PORT=43219\\n'; exec cat")
    assert {:ok, handle} = Wayland.spawn(%{input_authorized: true})
    Wayland.kill(handle)
  end

  test "spawn passes control only from resolved allow_input option" do
    helper("[ \"$*\" = '--allow-input' ] || exit 64; printf 'PORT=43219\\n'; exec cat")
    assert {:ok, handle} = Wayland.spawn(%{allow_input: true})
    Wayland.kill(handle)
  end

  test "trusted helper returns its ephemeral port and stop closes only its handle" do
    helper("printf 'PORT='; printf '43219\\n'; exec cat")
    assert {:ok, %{port_ref: port, vnc_port: 43_219} = handle} = Wayland.start()
    assert is_port(port)
    assert :ok = Wayland.stop(handle)
    assert Port.info(port) == nil
    assert :ok = Wayland.stop(handle)
  end

  test "invalid port is rejected and the helper is closed" do
    helper("printf 'PORT=65536\\n'; exec cat")
    assert {:error, :bad_port_value} = Wayland.start()
  end

  test "helper consent cancellation is returned as an error, never a port" do
    helper("exit 2")
    assert {:error, {:wayland_helper_exited, 2}} = Wayland.start()
  end

  test "oversized startup output is bounded" do
    helper("head -c 17000 /dev/zero; exec cat")
    assert {:error, :startup_output_limit} = Wayland.start()
  end

  defp helper(body) do
    path =
      Path.join(System.tmp_dir!(), "osa-wayland-contract-#{System.unique_integer([:positive])}")

    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    System.put_env("WAYLAND_DISPLAY", "test-only")
    System.put_env("XDG_RUNTIME_DIR", System.tmp_dir!())
    System.put_env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent-wayland-test-bus")
    System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", path)

    System.put_env(
      "OSA_DESKTOP_HELPER_SHA256",
      :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
    )
  end
end
