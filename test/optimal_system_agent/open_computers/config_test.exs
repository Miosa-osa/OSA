defmodule OptimalSystemAgent.OpenComputers.ConfigTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Config

  defp tmp_toml(content) do
    path =
      Path.join(System.tmp_dir!(), "oc_config_test_#{System.unique_integer([:positive])}.toml")

    File.write!(path, content)
    path
  end

  describe "Config GenServer — load from TOML" do
    test "starts successfully with a valid TOML file" do
      path =
        tmp_toml("""
        control_url = "wss://api.example.com/ws"
        host_key = "oc_host_abc123"
        fingerprint_path = "~/.osa/test.ed25519"
        heartbeat_ms = 15000
        modes = ["direct"]
        """)

      on_exit(fn -> File.rm(path) end)

      {:ok, pid} = start_supervised({Config, path: path}, id: :config_test_1)
      assert Process.alive?(pid)
    end

    test "get/0 returns parsed config" do
      path =
        tmp_toml("""
        control_url = "wss://api.example.com/ws"
        host_key = "oc_host_abc123"
        """)

      on_exit(fn -> File.rm(path) end)

      start_supervised!({Config, path: path}, id: :config_test_get)
      cfg = Config.get()
      assert cfg.control_url == "wss://api.example.com/ws"
      assert cfg.host_key == "oc_host_abc123"
    end

    test "defaults to direct mode when modes not specified" do
      path =
        tmp_toml("""
        host_key = "oc_host_abc"
        """)

      on_exit(fn -> File.rm(path) end)
      start_supervised!({Config, path: path}, id: :config_test_modes)
      cfg = Config.get()
      assert cfg.modes == ["direct"]
    end

    test "defaults heartbeat_ms to 30000 when not specified" do
      path =
        tmp_toml("""
        host_key = "oc_host_xyz"
        """)

      on_exit(fn -> File.rm(path) end)
      start_supervised!({Config, path: path}, id: :config_test_hb)
      cfg = Config.get()
      assert cfg.heartbeat_ms == 30_000
    end

    test "parses integer heartbeat_ms from TOML" do
      path =
        tmp_toml("""
        heartbeat_ms = 10000
        """)

      on_exit(fn -> File.rm(path) end)
      start_supervised!({Config, path: path}, id: :config_test_hb2)
      cfg = Config.get()
      assert cfg.heartbeat_ms == 10_000
    end

    test "parses modes array from TOML" do
      path = tmp_toml(~s(modes = ["direct", "vm_dispatch"]))

      on_exit(fn -> File.rm(path) end)
      start_supervised!({Config, path: path}, id: :config_test_arr)
      cfg = Config.get()
      assert "direct" in cfg.modes
      assert "vm_dispatch" in cfg.modes
    end

    test "falls back to defaults when file does not exist" do
      path = "/tmp/osa_config_nonexistent_#{System.unique_integer([:positive])}.toml"
      start_supervised!({Config, path: path}, id: :config_test_missing)
      cfg = Config.get()
      assert is_binary(cfg.control_url)
      assert cfg.heartbeat_ms == 30_000
    end
  end

  describe "Config GenServer — reload/0" do
    test "reload/0 re-reads from disk" do
      path =
        tmp_toml("""
        host_key = "oc_host_first"
        """)

      on_exit(fn -> File.rm(path) end)
      start_supervised!({Config, path: path}, id: :config_test_reload)
      assert Config.get().host_key == "oc_host_first"

      File.write!(path, ~s(host_key = "oc_host_second"\n))
      Config.reload()
      assert Config.get().host_key == "oc_host_second"
    end
  end

  describe "Config GenServer — env overrides" do
    test "OSA_OPEN_COMPUTERS_HOST_KEY overrides TOML value" do
      path =
        tmp_toml("""
        host_key = "oc_host_from_file"
        """)

      on_exit(fn ->
        File.rm(path)
        System.delete_env("OSA_OPEN_COMPUTERS_HOST_KEY")
      end)

      System.put_env("OSA_OPEN_COMPUTERS_HOST_KEY", "oc_host_from_env")
      start_supervised!({Config, path: path}, id: :config_test_env)
      cfg = Config.get()
      assert cfg.host_key == "oc_host_from_env"
    end
  end
end
