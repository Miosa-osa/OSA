defmodule OptimalSystemAgent.OpenComputers do
  @moduledoc """
  OpenComputers extension — connects this OSA installation to MIOSA's
  control plane so the host machine appears in the MIOSA frontend as
  an orchestrable Computer.

  Opt-in. Gated by `config :optimal_system_agent, :open_computers_enabled`
  (default `false`) or the `OSA_OPEN_COMPUTERS_ENABLED=true` env var.

  When enabled, OSA advertises one or more of three modes to the control
  plane at handshake:

    * `:direct`       — the host itself is the Computer. Native desktop
                        is streamed; OSA's own agent loop handles
                        `:dispatch_agent` jobs; `:exec_on_host` runs as
                        a shell subprocess.
    * `:slicing`      — (Phase 2) host carves sub-VMs via Apple
                        Containerization / Firecracker / Hyper-V.
    * `:vm_dispatch`  — (Phase 2) host is a Firecracker host.

  Protocol spec: `miosa-compute/docs/opencomputers-protocol.md` on the
  control-plane side.

  ## Startup

  `OptimalSystemAgent.OpenComputers.Supervisor` is a child of
  `OptimalSystemAgent.Supervisors.Extensions` — started only when the
  config flag is set. See `config/config.exs` for the flag and
  `lib/optimal_system_agent/supervisors/extensions.ex` for the wiring.
  """

  alias OptimalSystemAgent.OpenComputers.Config

  @doc "True if the extension is enabled AND the supervisor is alive."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :open_computers_enabled, false) == true and
      is_pid(Process.whereis(OptimalSystemAgent.OpenComputers.Supervisor))
  end

  @doc "Current runtime config snapshot (for status / debug)."
  @spec config() :: map()
  defdelegate config(), to: Config, as: :get
end
