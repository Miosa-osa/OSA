defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOSTest do
  @moduledoc """
  Unit tests for `Desktop.MacOS`.

  Tests marked `@tag :macos_native` require the compiled `osa-screen-capture-darwin`
  binary in `priv/helpers/` or `~/.osa/helpers/`. They are skipped on Linux/Windows
  CI — add `--include macos_native` on macOS runners with the built binary present.

  All other tests run on any platform and test the missing-binary path.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.MacOS

  @moduletag :open_computers

  # ── struct ─────────────────────────────────────────────────────────────────

  describe "MacOS struct" do
    test "can be constructed with expected fields" do
      ref = struct(MacOS, port: :port_ref, os_pid: 12345, vnc_port: 5900)
      assert ref.os_pid == 12345
      assert ref.vnc_port == 5900
    end
  end

  # ── spawn/0 — binary missing ───────────────────────────────────────────────

  describe "spawn/0 when helper binary is missing" do
    test "returns {:error, {:missing_helper, _}} when neither path exists" do
      # Only run if the binary is genuinely absent (non-macOS CI, or macOS without build).
      user_path = Path.expand("~/.osa/helpers/osa-screen-capture-darwin")

      priv_path =
        Path.join(:code.priv_dir(:optimal_system_agent), "helpers/osa-screen-capture-darwin")

      if File.exists?(user_path) or File.exists?(priv_path) do
        # Binary present — can't test missing path in isolation
        :ok
      else
        result = MacOS.spawn()
        assert {:error, {:missing_helper, msg}} = result
        assert is_binary(msg)
        assert String.contains?(msg, "osa-screen-capture-darwin")
      end
    end
  end

  # ── real binary tests — macOS runners only ─────────────────────────────────

  describe "spawn/0 with real binary (macos_native)" do
    @tag :macos_native
    test "spawns helper, receives PORT= announcement, VNC port is reachable" do
      priv_path =
        Path.join(:code.priv_dir(:optimal_system_agent), "helpers/osa-screen-capture-darwin")

      if not File.exists?(priv_path) do
        IO.puts("Skipping macos_native test: binary not found at #{priv_path}")
        :ok
      else
        assert {:ok, %MacOS{os_pid: os_pid, vnc_port: vnc_port}} = MacOS.spawn()

        assert is_integer(os_pid) and os_pid > 0
        assert is_integer(vnc_port) and vnc_port > 0

        # Verify RFB handshake
        assert {:ok, sock} =
                 :gen_tcp.connect(~c"127.0.0.1", vnc_port, [:binary, active: false], 2_000)

        assert {:ok, version} = :gen_tcp.recv(sock, 12, 2_000)
        assert version == "RFB 003.008\n"

        :gen_tcp.close(sock)
        System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
      end
    end
  end
end
