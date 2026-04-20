defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOSTest do
  @moduledoc """
  Unit tests for `Desktop.MacOS`.

  Tests marked `@moduletag :macos_native` require the compiled ScreenShare
  binary. They are skipped on Linux/Windows CI automatically — add
  `--include macos_native` on macOS runners with the built binary present.

  All other tests run on any platform.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOS

  @moduletag :open_computers

  # ── available?/0 ─────────────────────────────────────────────────────────────

  describe "available?/0" do
    test "returns false when binary does not exist" do
      System.put_env("OSA_MACOS_HELPER", "/nonexistent/path/ScreenShare")

      assert MacOS.available?() == false

      System.delete_env("OSA_MACOS_HELPER")
    end

    test "returns true when binary exists" do
      # Create a temp file to simulate the binary being present
      tmp = System.tmp_dir!() |> Path.join("osa_test_screenshare_#{:erlang.unique_integer([:positive])}")
      File.write!(tmp, "fake binary")
      File.chmod!(tmp, 0o755)

      System.put_env("OSA_MACOS_HELPER", tmp)

      assert MacOS.available?() == true

      System.delete_env("OSA_MACOS_HELPER")
      File.rm(tmp)
    end
  end

  # ── start/1 — binary missing ─────────────────────────────────────────────────

  describe "start/1 when binary is missing" do
    test "returns {:error, :helper_not_installed}" do
      System.put_env("OSA_MACOS_HELPER", "/nonexistent/ScreenShare")

      assert {:error, :helper_not_installed} = MacOS.start()

      System.delete_env("OSA_MACOS_HELPER")
    end

    test "returns tagged error even with custom port option" do
      System.put_env("OSA_MACOS_HELPER", "/nonexistent/ScreenShare")

      assert {:error, :helper_not_installed} = MacOS.start(port: 15_900)

      System.delete_env("OSA_MACOS_HELPER")
    end
  end

  # ── helper_path/0 ─────────────────────────────────────────────────────────────

  describe "helper_path/0" do
    test "respects OSA_MACOS_HELPER env var" do
      System.put_env("OSA_MACOS_HELPER", "/custom/path/ScreenShare")
      assert MacOS.helper_path() == "/custom/path/ScreenShare"
      System.delete_env("OSA_MACOS_HELPER")
    end

    test "falls back to priv dir when env var is unset" do
      System.delete_env("OSA_MACOS_HELPER")
      path = MacOS.helper_path()
      # Should contain priv/macos/ScreenShare
      assert String.contains?(path, Path.join(["macos", "ScreenShare"]))
    end
  end

  # ── stop/1 ────────────────────────────────────────────────────────────────────

  describe "stop/1" do
    test "accepts nil without crashing" do
      assert :ok = MacOS.stop(nil)
    end
  end

  # ── real binary tests — macOS runners only ────────────────────────────────────

  @moduletag :macos_native

  describe "start/1 with real binary (macos_native)" do
    @tag :macos_native
    test "starts the helper in stub mode and TCP port becomes reachable" do
      # Locate the built binary relative to the project root.
      # CI builds it before running tests; local dev: `swift build -c release` first.
      helper_bin =
        [File.cwd!(), "native", "macos", "ScreenShare", ".build", "release", "ScreenShare"]
        |> Path.join()

      if not File.exists?(helper_bin) do
        ExUnit.configure(exclude: [:macos_native])
        :ok
      else
        System.put_env("OSA_MACOS_HELPER", helper_bin)

        port = 15_901
        assert {:ok, port_ref} = MacOS.start(port: port, stub: true)

        # Give the binary a moment to bind the port
        Process.sleep(300)

        # Verify TCP port is reachable — proves RFB server bound successfully
        assert {:ok, sock} =
                 :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)

        # The first bytes should be the RFB version string "RFB 003.008\n"
        assert {:ok, version} = :gen_tcp.recv(sock, 12, 2_000)
        assert version == "RFB 003.008\n"

        :gen_tcp.close(sock)
        MacOS.stop(port_ref)

        System.delete_env("OSA_MACOS_HELPER")
      end
    end
  end
end
