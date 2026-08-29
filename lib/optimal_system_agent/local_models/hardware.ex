defmodule OptimalSystemAgent.LocalModels.Hardware do
  @moduledoc """
  What this machine can run a local model on.

  Detected once and cached in `:persistent_term` (call `refresh/0` to redo):
  GPU name + VRAM, system RAM, CPU, and the accelerator backend. The numbers
  feed `LocalModels.Fit` — will the weights fit, how fast will decode be.

  Every probe is best-effort and degrades to "unknown" (nil / 0) rather than
  raising; a machine with no `nvidia-smi` is a CPU box, not an error.
  """

  @type t :: %{
          backend: :cuda | :rocm | :metal | :cpu,
          gpu: String.t() | nil,
          vram_bytes: non_neg_integer(),
          ram_bytes: non_neg_integer(),
          cpu: String.t() | nil,
          cores: pos_integer(),
          os: :linux | :macos | :windows | :other,
          # Memory bandwidth the decode loop is bound by, in GB/s. From a
          # lookup on the GPU name; a guess is flagged so the UI can say "est."
          bandwidth_gbps: number(),
          bandwidth_known: boolean()
        }

  @key {__MODULE__, :detected}

  @spec detect() :: t()
  def detect do
    case :persistent_term.get(@key, nil) do
      nil -> refresh()
      hw -> hw
    end
  end

  @spec refresh() :: t()
  def refresh do
    hw = probe()
    :persistent_term.put(@key, hw)
    hw
  end

  @doc "Build the record from raw probe results (test seam — no shelling out)."
  @spec from_probe(map()) :: t()
  def from_probe(raw) do
    os = Map.get(raw, :os, :linux)
    ram = Map.get(raw, :ram_bytes, 0)
    {gpu, vram, backend} = pick_gpu(raw, os, ram)
    {bw, known} = bandwidth_for(gpu, backend, os)

    %{
      backend: backend,
      gpu: gpu,
      vram_bytes: vram,
      ram_bytes: ram,
      cpu: Map.get(raw, :cpu),
      cores: Map.get(raw, :cores, System.schedulers_online()),
      os: os,
      bandwidth_gbps: bw,
      bandwidth_known: known
    }
  end

  @doc "One-line summary for status lines: `RTX 5090 Laptop · 24 GB VRAM · 64 GB RAM`."
  @spec summary(t()) :: String.t()
  def summary(hw) do
    gpu =
      case hw.gpu do
        nil -> "no GPU (#{hw.cpu || "cpu"})"
        name -> "#{shorten_gpu(name)} · #{gb(hw.vram_bytes)} GB VRAM"
      end

    "#{gpu} · #{gb(hw.ram_bytes)} GB RAM"
  end

  @doc false
  def shorten_gpu(name) do
    name
    |> String.replace(~r/^NVIDIA (GeForce )?/, "")
    |> String.replace(~r/ GPU$/, "")
    |> String.replace("Apple ", "")
  end

  defp gb(bytes), do: Float.round(bytes / 1024 / 1024 / 1024, 0) |> trunc()

  # ── probing ─────────────────────────────────────────────────────────────

  defp probe do
    os = host_os()

    from_probe(%{
      os: os,
      ram_bytes: ram_bytes(os),
      cpu: cpu_name(os),
      cores: System.schedulers_online(),
      nvidia: nvidia_smi(),
      amd_vram: amd_vram(os),
      apple_chip: apple_chip(os)
    })
  end

  defp pick_gpu(raw, os, ram) do
    cond do
      match?({name, vram} when is_binary(name) and vram > 0, Map.get(raw, :nvidia)) ->
        {name, vram} = raw.nvidia
        {name, vram, :cuda}

      is_integer(Map.get(raw, :amd_vram)) and raw.amd_vram > 0 ->
        {"AMD GPU", raw.amd_vram, :rocm}

      os == :macos and is_binary(Map.get(raw, :apple_chip)) ->
        # Unified memory: Metal lets a process use roughly 3/4 of RAM by default.
        {raw.apple_chip, div(ram * 3, 4), :metal}

      true ->
        {nil, 0, :cpu}
    end
  end

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
      {:win32, _} -> :windows
      _ -> :other
    end
  end

  defp nvidia_smi do
    case run("nvidia-smi", ["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"]) do
      {:ok, out} ->
        # Multi-GPU: take the largest card. Fit against one device is the
        # honest answer — Ollama splits across cards, but bandwidth does not add.
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, ",") do
            [name, mib | _] ->
              {String.trim(name), (mib |> String.trim() |> to_int()) * 1024 * 1024}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(&elem(&1, 1), fn -> nil end)

      _ ->
        nil
    end
  end

  defp amd_vram(:linux) do
    Path.wildcard("/sys/class/drm/card*/device/mem_info_vram_total")
    |> Enum.map(fn p ->
      case File.read(p) do
        {:ok, s} -> to_int(String.trim(s))
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp amd_vram(_), do: 0

  defp apple_chip(:macos) do
    case run("sysctl", ["-n", "machdep.cpu.brand_string"]) do
      {:ok, s} -> String.trim(s)
      _ -> nil
    end
  end

  defp apple_chip(_), do: nil

  defp ram_bytes(:linux) do
    case File.read("/proc/meminfo") do
      {:ok, s} ->
        case Regex.run(~r/MemTotal:\s+(\d+) kB/, s) do
          [_, kb] -> to_int(kb) * 1024
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp ram_bytes(:macos) do
    case run("sysctl", ["-n", "hw.memsize"]) do
      {:ok, s} -> to_int(String.trim(s))
      _ -> 0
    end
  end

  defp ram_bytes(_), do: 0

  defp cpu_name(:linux) do
    case File.read("/proc/cpuinfo") do
      {:ok, s} ->
        case Regex.run(~r/model name\s*:\s*(.+)/, s) do
          [_, name] -> String.trim(name)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp cpu_name(:macos), do: apple_chip(:macos)
  defp cpu_name(_), do: nil

  defp run(cmd, args) do
    case System.find_executable(cmd) do
      nil ->
        :error

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # ── bandwidth table ─────────────────────────────────────────────────────
  #
  # Decode is memory-bandwidth-bound: every generated token streams the active
  # weights once. GB/s per part, most specific pattern first. Not exhaustive —
  # an unmatched GPU gets a conservative default and `bandwidth_known: false`.
  @gpu_bandwidth [
    {"5090 laptop", 896},
    {"5080 laptop", 896},
    {"5070 ti laptop", 672},
    {"5070 laptop", 384},
    {"5060 laptop", 384},
    {"5090", 1792},
    {"5080", 960},
    {"5070 ti", 896},
    {"5070", 672},
    {"5060 ti", 448},
    {"5060", 448},
    {"4090 laptop", 576},
    {"4080 laptop", 432},
    {"4070 laptop", 256},
    {"4060 laptop", 256},
    {"4090", 1008},
    {"4080", 717},
    {"4070 ti", 504},
    {"4070", 504},
    {"4060 ti", 288},
    {"4060", 272},
    {"3090", 936},
    {"3080", 760},
    {"3070", 448},
    {"3060", 360},
    {"h200", 4800},
    {"h100", 3350},
    {"a100", 1935},
    {"l40", 864},
    {"a6000", 768},
    {"rtx 6000", 960},
    {"a10", 600},
    {"7900 xtx", 960},
    {"7900", 800},
    {"m4 max", 546},
    {"m4 pro", 273},
    {"m4", 120},
    {"m3 ultra", 819},
    {"m3 max", 400},
    {"m3 pro", 150},
    {"m3", 100},
    {"m2 ultra", 800},
    {"m2 max", 400},
    {"m2 pro", 200},
    {"m2", 100},
    {"m1 ultra", 800},
    {"m1 max", 400},
    {"m1 pro", 200},
    {"m1", 68}
  ]

  @default_gpu_bandwidth 450
  # Dual-channel DDR5 on a desktop/laptop; what CPU-offloaded layers get.
  @cpu_bandwidth 60

  @doc false
  def cpu_bandwidth_gbps, do: @cpu_bandwidth

  @doc false
  @spec bandwidth_for(String.t() | nil, atom(), atom()) :: {number(), boolean()}
  def bandwidth_for(nil, _backend, _os), do: {@cpu_bandwidth, true}

  def bandwidth_for(gpu, _backend, _os) do
    name = String.downcase(gpu)

    case Enum.find(@gpu_bandwidth, fn {pat, _} -> String.contains?(name, pat) end) do
      {_, bw} -> {bw, true}
      nil -> {@default_gpu_bandwidth, false}
    end
  end
end
