defmodule OptimalSystemAgent.OpenComputers.Session.Hello do
  @moduledoc """
  Builds the `{:hello, _}` frame payload sent on connect.

  Pure functions — composes values from Config, Telemetry, and
  Fingerprint. Derives the capability list from the configured modes
  with OS-appropriate slicing backends.
  """

  alias OptimalSystemAgent.OpenComputers.Session.Fingerprint
  alias OptimalSystemAgent.OpenComputers.Telemetry

  @spec build(map()) :: map()
  def build(cfg) do
    %{
      host_key: cfg.host_key,
      fingerprint: Fingerprint.load_or_generate(cfg.fingerprint_path),
      version: osa_version(),
      capabilities: derive_capabilities(cfg.modes),
      modes: cfg.modes,
      capacity: Telemetry.capacity(),
      os: Telemetry.os_info()
    }
  end

  @spec derive_capabilities([String.t()]) :: [atom()]
  def derive_capabilities(modes) do
    modes
    |> Enum.flat_map(&capabilities_for_mode/1)
    |> Enum.uniq()
  end

  # ── Private ──

  defp capabilities_for_mode("direct"), do: [:native_desktop, :native_exec, :osa_runtime]
  defp capabilities_for_mode("vm_dispatch"), do: [:firecracker]
  defp capabilities_for_mode("slicing"), do: [slice_backend_for_host()]
  defp capabilities_for_mode(_), do: []

  defp slice_backend_for_host do
    case :os.type() do
      {:unix, :darwin} -> :apple_containerization
      {:unix, :linux} -> :firecracker
      {:win32, _} -> :hyper_v
      _ -> :firecracker
    end
  end

  defp osa_version do
    case Application.spec(:optimal_system_agent, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
