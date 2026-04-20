defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.WindowsTest do
  @moduledoc """
  Unit tests for `Desktop.Windows`.

  Tests marked `@moduletag :windows_native` require the compiled ScreenShare.exe.
  They are excluded on non-Windows runners via `mix test --exclude windows_native`.

  All other tests run on any platform.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Windows

  @moduletag :open_computers

  # ── available?/0 ─────────────────────────────────────────────────────────────

  describe "available?/0" do
    test "returns false when binary does not exist" do
      System.put_env("OSA_WINDOWS_HELPER", "/nonexistent/ScreenShare.exe")

      assert Windows.available?() == false

      System.delete_env("OSA_WINDOWS_HELPER")
    end

    test "returns true when binary exists" do
      tmp = System.tmp_dir!() |> Path.join("osa_test_screenshare_#{:erlang.unique_integer([:positive])}.exe")
      File.write!(tmp, "fake binary")

      System.put_env("OSA_WINDOWS_HELPER", tmp)

      assert Windows.available?() == true

      System.delete_env("OSA_WINDOWS_HELPER")
      File.rm(tmp)
    end
  end

  # ── start/1 — binary missing ─────────────────────────────────────────────────

  describe "start/1 when binary is missing" do
    test "returns {:error, :helper_not_installed}" do
      System.put_env("OSA_WINDOWS_HELPER", "/nonexistent/ScreenShare.exe")

      assert {:error, :helper_not_installed} = Windows.start()

      System.delete_env("OSA_WINDOWS_HELPER")
    end

    test "returns tagged error even with custom options" do
      System.put_env("OSA_WINDOWS_HELPER", "/nonexistent/ScreenShare.exe")

      assert {:error, :helper_not_installed} = Windows.start(port: 15_900, stub: true)

      System.delete_env("OSA_WINDOWS_HELPER")
    end
  end

  # ── helper_path/0 ─────────────────────────────────────────────────────────────

  describe "helper_path/0" do
    test "respects OSA_WINDOWS_HELPER env var" do
      System.put_env("OSA_WINDOWS_HELPER", "C:\\custom\\ScreenShare.exe")
      assert Windows.helper_path() == "C:\\custom\\ScreenShare.exe"
      System.delete_env("OSA_WINDOWS_HELPER")
    end

    test "falls back to priv dir when env var is unset" do
      System.delete_env("OSA_WINDOWS_HELPER")
      path = Windows.helper_path()
      assert String.contains?(path, Path.join(["windows", "ScreenShare.exe"]))
    end
  end

  # ── stop/1 ────────────────────────────────────────────────────────────────────

  describe "stop/1" do
    test "accepts nil without crashing" do
      assert :ok = Windows.stop(nil)
    end
  end

  # ── real binary tests — Windows runners only ──────────────────────────────────

  @moduletag :windows_native

  describe "start/1 with real binary (windows_native)" do
    @tag :windows_native
    test "starts the helper in stub mode and TCP port becomes reachable" do
      helper_bin =
        [File.cwd!(), "native", "windows", "ScreenShare", "publish", "ScreenShare.exe"]
        |> Path.join()

      if not File.exists?(helper_bin) do
        :ok
      else
        System.put_env("OSA_WINDOWS_HELPER", helper_bin)

        port = 15_902
        assert {:ok, port_ref} = Windows.start(port: port, stub: true)

        Process.sleep(500)

        assert {:ok, sock} =
                 :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)

        assert {:ok, version} = :gen_tcp.recv(sock, 12, 2_000)
        assert version == "RFB 003.008\n"

        :gen_tcp.close(sock)
        Windows.stop(port_ref)

        System.delete_env("OSA_WINDOWS_HELPER")
      end
    end
  end
end
