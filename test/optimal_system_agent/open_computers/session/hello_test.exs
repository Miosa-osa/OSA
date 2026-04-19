defmodule OptimalSystemAgent.OpenComputers.Session.HelloTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Session.Hello

  describe "derive_capabilities/1" do
    test "direct mode includes native_desktop, native_exec, osa_runtime" do
      caps = Hello.derive_capabilities(["direct"])
      assert :native_desktop in caps
      assert :native_exec in caps
      assert :osa_runtime in caps
    end

    test "vm_dispatch mode includes :firecracker" do
      caps = Hello.derive_capabilities(["vm_dispatch"])
      assert :firecracker in caps
    end

    test "slicing mode returns a backend atom" do
      caps = Hello.derive_capabilities(["slicing"])
      assert length(caps) == 1
      assert is_atom(hd(caps))
    end

    test "unknown mode returns empty list" do
      caps = Hello.derive_capabilities(["unknown_mode"])
      assert caps == []
    end

    test "empty modes returns empty list" do
      assert Hello.derive_capabilities([]) == []
    end

    test "multiple modes are unioned" do
      caps = Hello.derive_capabilities(["direct", "vm_dispatch"])
      assert :native_desktop in caps
      assert :firecracker in caps
    end

    test "duplicate modes produce unique capabilities" do
      caps = Hello.derive_capabilities(["direct", "direct"])
      assert caps == Enum.uniq(caps)
    end

    test "direct + vm_dispatch have at least 4 capabilities" do
      caps = Hello.derive_capabilities(["direct", "vm_dispatch"])
      assert length(caps) >= 4
    end

    test "unknown modes do not add to capability list" do
      caps_direct = Hello.derive_capabilities(["direct"])
      caps_mixed = Hello.derive_capabilities(["direct", "bogus"])
      assert caps_direct == caps_mixed
    end
  end

  describe "build/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "hello_test_fp_#{System.unique_integer([:positive])}")
      cfg = %{
        host_key: "oc_host_testkey",
        fingerprint_path: tmp,
        modes: ["direct"]
      }
      on_exit(fn -> File.rm(tmp) end)
      {:ok, cfg: cfg}
    end

    test "returns a map with required keys", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert is_map(result)
      assert Map.has_key?(result, :host_key)
      assert Map.has_key?(result, :fingerprint)
      assert Map.has_key?(result, :version)
      assert Map.has_key?(result, :capabilities)
      assert Map.has_key?(result, :modes)
      assert Map.has_key?(result, :capacity)
      assert Map.has_key?(result, :os)
    end

    test "host_key matches config", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert result.host_key == "oc_host_testkey"
    end

    test "modes matches config", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert result.modes == ["direct"]
    end

    test "version is a string", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert is_binary(result.version)
    end

    test "capabilities is a list of atoms", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert is_list(result.capabilities)
      assert Enum.all?(result.capabilities, &is_atom/1)
    end

    test "capacity is a map with cpu, memory_mb, disk_gb", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert is_map(result.capacity)
      assert Map.has_key?(result.capacity, :cpu)
      assert Map.has_key?(result.capacity, :memory_mb)
      assert Map.has_key?(result.capacity, :disk_gb)
    end

    test "os is a map with kind, version, arch", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert is_map(result.os)
      assert Map.has_key?(result.os, :kind)
      assert Map.has_key?(result.os, :version)
      assert Map.has_key?(result.os, :arch)
    end

    test "fingerprint is binary with 32 bytes", %{cfg: cfg} do
      result = Hello.build(cfg)
      assert is_binary(result.fingerprint)
      assert byte_size(result.fingerprint) == 32
    end
  end
end
