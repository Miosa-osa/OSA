defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.WindowsTest do
  @moduledoc """
  Unit tests for `Desktop.Windows`.

  Tests marked `@tag :windows_native` require the compiled
  `osa-screen-capture-windows.exe` in `priv/helpers/` or
  `%USERPROFILE%\\.osa\\helpers\\`. They are skipped on Linux/macOS CI —
  add `--include windows_native` on Windows runners with the built binary present.

  All other tests run on any platform and test the missing-binary path.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Windows

  @moduletag :open_computers

  # ── struct ─────────────────────────────────────────────────────────────────

  describe "Windows struct" do
    test "can be constructed with expected fields" do
      ref = struct(Windows, port: :port_ref, os_pid: 9999, vnc_port: 5900)
      assert ref.os_pid == 9999
      assert ref.vnc_port == 5900
    end
  end

  # ── spawn/0 — binary missing ───────────────────────────────────────────────

  describe "spawn/0 when helper binary is missing" do
    test "returns {:error, {:missing_helper, _}} when neither path exists" do
      # Only run if the binary is genuinely absent (Linux/macOS CI, or Windows without build).
      priv_path =
        Path.join(:code.priv_dir(:optimal_system_agent), "helpers/osa-screen-capture-windows.exe")

      user_path =
        case System.get_env("USERPROFILE") do
          nil -> nil
          profile -> Path.join([profile, ".osa", "helpers", "osa-screen-capture-windows.exe"])
        end

      binary_present =
        File.exists?(priv_path) or (not is_nil(user_path) and File.exists?(user_path))

      if binary_present do
        # Binary present — can't test missing path in isolation
        :ok
      else
        result = Windows.spawn()
        assert {:error, {:missing_helper, msg}} = result
        assert is_binary(msg)
        assert String.contains?(msg, "osa-screen-capture-windows.exe")
      end
    end
  end

  # ── real binary tests — Windows runners only ──────────────────────────────

  describe "spawn/0 with real binary (windows_native)" do
    @tag :windows_native
    test "spawns helper, receives PORT= announcement, VNC port is reachable" do
      priv_path =
        Path.join(
          :code.priv_dir(:optimal_system_agent),
          "helpers/osa-screen-capture-windows.exe"
        )

      if not File.exists?(priv_path) do
        IO.puts("Skipping windows_native test: binary not found at #{priv_path}")
        :ok
      else
        assert {:ok, %Windows{os_pid: os_pid, vnc_port: vnc_port} = ref} = Windows.spawn()

        assert is_integer(os_pid) and os_pid > 0
        assert is_integer(vnc_port) and vnc_port > 0

        # Verify RFB handshake
        assert {:ok, sock} =
                 :gen_tcp.connect(~c"127.0.0.1", vnc_port, [:binary, active: false], 2_000)

        assert {:ok, version} = :gen_tcp.recv(sock, 12, 2_000)
        assert version == "RFB 003.008\n"

        :gen_tcp.close(sock)
        Windows.kill(ref)
      end
    end
  end
end
