defmodule OptimalSystemAgent.OpenComputers.Telemetry.Power do
  @moduledoc """
  Power-source detection. Phase 1 stub — returns `"unknown"`.

  Phase 2+ will implement per-OS detection (pmset on macOS,
  /sys/class/power_supply on Linux, GetSystemPowerStatus on Windows).
  """

  @spec source() :: String.t()
  def source, do: "unknown"
end
