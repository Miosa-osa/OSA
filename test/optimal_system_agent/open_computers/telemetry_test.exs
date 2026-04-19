defmodule OptimalSystemAgent.OpenComputers.TelemetryTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Telemetry
  alias OptimalSystemAgent.OpenComputers.Telemetry.{Cpu, Disk, Memory, Os, Power}

  describe "Telemetry.capacity/0" do
    test "returns a map" do
      result = Telemetry.capacity()
      assert is_map(result)
    end

    test "has :cpu key with non-negative integer" do
      result = Telemetry.capacity()
      assert Map.has_key?(result, :cpu)
      assert is_integer(result.cpu) and result.cpu >= 0
    end

    test "has :memory_mb key with non-negative integer" do
      result = Telemetry.capacity()
      assert Map.has_key?(result, :memory_mb)
      assert is_integer(result.memory_mb) and result.memory_mb >= 0
    end

    test "has :disk_gb key with non-negative integer" do
      result = Telemetry.capacity()
      assert Map.has_key?(result, :disk_gb)
      assert is_integer(result.disk_gb) and result.disk_gb >= 0
    end
  end

  describe "Telemetry.live/0" do
    test "returns a map" do
      result = Telemetry.live()
      assert is_map(result)
    end

    test "has :load_avg_1m as float >= 0" do
      result = Telemetry.live()
      assert Map.has_key?(result, :load_avg_1m)
      assert is_float(result.load_avg_1m) and result.load_avg_1m >= 0.0
    end

    test "has :ram_used_mb as non-negative integer" do
      result = Telemetry.live()
      assert is_integer(result.ram_used_mb) and result.ram_used_mb >= 0
    end

    test "has :ram_free_mb as non-negative integer" do
      result = Telemetry.live()
      assert is_integer(result.ram_free_mb) and result.ram_free_mb >= 0
    end

    test "has :disk_free_gb as non-negative integer" do
      result = Telemetry.live()
      assert is_integer(result.disk_free_gb) and result.disk_free_gb >= 0
    end

    test "has :power as string" do
      result = Telemetry.live()
      assert is_binary(result.power)
    end

    test "has :active_sessions defaulting to 0" do
      result = Telemetry.live()
      assert result.active_sessions == 0
    end

    test "accepts :active_sessions override via opts" do
      result = Telemetry.live(active_sessions: 5)
      assert result.active_sessions == 5
    end
  end

  describe "Telemetry.os_info/0" do
    test "returns a map" do
      result = Telemetry.os_info()
      assert is_map(result)
    end

    test "has :kind as non-empty string" do
      result = Telemetry.os_info()
      assert is_binary(result.kind) and result.kind != ""
    end

    test "has :version as string" do
      result = Telemetry.os_info()
      assert is_binary(result.version)
    end

    test "has :arch as non-empty string" do
      result = Telemetry.os_info()
      assert is_binary(result.arch) and result.arch != ""
    end
  end

  describe "Telemetry.Cpu" do
    test "cores/0 returns a positive integer" do
      cores = Cpu.cores()
      assert is_integer(cores) and cores > 0
    end

    test "load_avg_1m/0 returns a float >= 0.0" do
      avg = Cpu.load_avg_1m()
      assert is_float(avg) and avg >= 0.0
    end
  end

  describe "Telemetry.Memory" do
    test "total_mb/0 returns non-negative integer (0 when :memsup unavailable)" do
      result = Memory.total_mb()
      assert is_integer(result) and result >= 0
    end

    test "used_mb/0 returns non-negative integer" do
      result = Memory.used_mb()
      assert is_integer(result) and result >= 0
    end

    test "free_mb/0 returns non-negative integer" do
      result = Memory.free_mb()
      assert is_integer(result) and result >= 0
    end
  end

  describe "Telemetry.Disk" do
    test "free_gb/0 returns non-negative integer" do
      result = Disk.free_gb()
      assert is_integer(result) and result >= 0
    end
  end

  describe "Telemetry.Os" do
    test "info/0 returns map with kind, version, arch" do
      info = Os.info()
      assert is_map(info)
      assert Map.keys(info) -- [:kind, :version, :arch] == []
    end

    test "kind is darwin, linux, windows or other string" do
      info = Os.info()
      assert info.kind in ["darwin", "linux", "windows"] or is_binary(info.kind)
    end
  end

  describe "Telemetry.Power" do
    test "source/0 returns a string" do
      assert is_binary(Power.source())
    end

    test "source/0 currently returns \"unknown\"" do
      assert Power.source() == "unknown"
    end
  end
end
