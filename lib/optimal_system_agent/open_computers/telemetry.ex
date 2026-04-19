defmodule OptimalSystemAgent.OpenComputers.Telemetry do
  @moduledoc """
  Host resource snapshots facade for the OpenComputers hello + heartbeat
  frames. Composes per-metric submodules:

    * `Telemetry.Os`     — kind/version/arch
    * `Telemetry.Memory` — total/used/free MB via `:memsup`
    * `Telemetry.Cpu`    — cores + 1-min load avg via `:cpu_sup`
    * `Telemetry.Disk`   — free GB on root mount via `:disksup`
    * `Telemetry.Power`  — ac / battery / unknown (stub)
  """

  alias OptimalSystemAgent.OpenComputers.Telemetry.{Cpu, Disk, Memory, Os, Power}

  @doc "Fixed host facts snapshot (hello frame)."
  @spec capacity() :: %{cpu: non_neg_integer(), memory_mb: non_neg_integer(), disk_gb: non_neg_integer()}
  def capacity do
    %{cpu: Cpu.cores(), memory_mb: Memory.total_mb(), disk_gb: Disk.free_gb()}
  end

  @doc "Live telemetry for heartbeats."
  @spec live(keyword()) :: map()
  def live(opts \\ []) do
    %{
      load_avg_1m: Cpu.load_avg_1m(),
      ram_used_mb: Memory.used_mb(),
      ram_free_mb: Memory.free_mb(),
      disk_free_gb: Disk.free_gb(),
      power: Power.source(),
      active_sessions: Keyword.get(opts, :active_sessions, 0)
    }
  end

  defdelegate os_info(), to: Os, as: :info
end
