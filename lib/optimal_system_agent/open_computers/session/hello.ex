defmodule OptimalSystemAgent.OpenComputers.Session.Hello do
  @moduledoc """
  Builds the `{:hello, _}` frame payload sent on connect.

  Composes values from Config, Telemetry, and Fingerprint.
  Capabilities describe implemented OSA job handlers, not workload readiness.
  Standalone workload capacity is independently authenticated and verified
  through the host-runtime protocol, never inferred from this machine's OS.
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
  # Executor dispatch does not implement create_computer/snapshot/restore.
  # Advertising these here makes the server route jobs that OSA must reject.
  defp capabilities_for_mode("vm_dispatch"), do: []
  defp capabilities_for_mode("slicing"), do: []
  defp capabilities_for_mode(_), do: []

  defp osa_version do
    case Application.spec(:optimal_system_agent, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
