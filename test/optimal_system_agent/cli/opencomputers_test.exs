defmodule OptimalSystemAgent.CLI.OpenComputersTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.CLI.OpenComputers

  # Each test gets an isolated ~/.osa via OSA_HOME so we never touch the real
  # config and never open a network connection to api.miosa.ai.
  setup do
    dir = Path.join(System.tmp_dir!(), "osa_oc_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if prev, do: System.put_env("OSA_HOME", prev), else: System.delete_env("OSA_HOME")
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp toml_path(dir), do: Path.join(dir, "open_computers.toml")

  describe "login (non-interactive) writes a well-formed config" do
    test "writes host_key, control_url, modes, heartbeat + placeholder fingerprint", %{dir: dir} do
      ExUnit.CaptureIO.capture_io(fn ->
        OpenComputers.dispatch(["login", "--key", "oc_host_abc123", "--force"])
      end)

      body = File.read!(toml_path(dir))
      assert body =~ ~s(host_key         = "oc_host_abc123")
      assert body =~ ~s(control_url      = "wss://api.miosa.ai)
      assert body =~ ~s(modes            = ["direct"])
      assert body =~ "heartbeat_ms     = 30000"

      # Placeholder fingerprint file created; empty is fine (Fingerprint
      # regenerates a real key at startup).
      assert File.exists?(Path.join(dir, "open_computers.ed25519"))

      # 0600 perms on the secret-bearing config
      {:ok, %{mode: mode}} = File.stat(toml_path(dir))
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end

  describe "TOML round-trip via login -> logout does not corrupt non-cleared keys" do
    test "logout clears host_key but preserves control_url/modes/heartbeat", %{dir: dir} do
      ExUnit.CaptureIO.capture_io(fn ->
        OpenComputers.dispatch([
          "login",
          "--key",
          "oc_host_secret",
          "--control-url",
          "wss://api.example.com/ws",
          "--force"
        ])
      end)

      before = File.read!(toml_path(dir))
      assert before =~ ~s(host_key         = "oc_host_secret")

      ExUnit.CaptureIO.capture_io(fn ->
        OpenComputers.dispatch(["logout", "--force"])
      end)

      after_body = File.read!(toml_path(dir))
      # host_key cleared…
      assert after_body =~ ~s(host_key         = "")
      refute after_body =~ "oc_host_secret"
      # …but the other keys survived the read/write round-trip intact.
      assert after_body =~ ~s(control_url      = "wss://api.example.com/ws")
      assert after_body =~ ~s(modes            = ["direct"])
      assert after_body =~ "heartbeat_ms     = 30000"
    end
  end

  describe "connection_verdict/3 — status summariser" do
    test "no host key -> not connected, points at login" do
      {verdict, hint} = OpenComputers.connection_verdict(true, false, "not running")
      assert verdict =~ "NOT connected"
      assert verdict =~ "no host key"
      assert hint =~ "login"
    end

    test "key present but disabled -> not connected, points at enable" do
      {verdict, hint} = OpenComputers.connection_verdict(false, true, "not running")
      assert verdict =~ "NOT connected"
      assert verdict =~ "disabled"
      assert hint =~ "enable"
    end

    test "enabled + key + session active -> connected, no hint" do
      {verdict, hint} = OpenComputers.connection_verdict(true, true, "connected (active)")
      assert verdict =~ "CONNECTED"
      assert is_nil(hint)
    end

    test "enabled + key but session not running -> restart hint" do
      {verdict, hint} = OpenComputers.connection_verdict(true, true, "not running")
      assert verdict =~ "NOT connected"
      assert hint =~ "restart"
    end

    test "enabled + key + session mid-handshake -> connecting" do
      {verdict, hint} = OpenComputers.connection_verdict(true, true, "running (phase=awaiting_hello_ok)")
      assert verdict =~ "connecting"
      assert is_binary(hint)
    end
  end
end
