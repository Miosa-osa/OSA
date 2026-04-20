defmodule OptimalSystemAgent.OpenComputers.Supervisor do
  @moduledoc """
  Extension supervisor for the OpenComputers subsystem.

  Children (started in order, strategy: one_for_one):

    * `OpenComputers.Config`                          — TOML + env loader, cached via GenServer
    * `OpenComputers.FrameRouter`                     — outbound frame fan-out to registered Session pid
    * `OpenComputers.Executor.Supervisor`             — DynamicSupervisor for per-job processes
    * `OpenComputers.Executor.Direct.Pty`             — long-lived PTY session manager
    * `OpenComputers.Executor.Direct.Desktop.Controller` — long-lived desktop relay manager
    * `OpenComputers.Updater`                         — periodic self-update poller
    * `OpenComputers.Session`                         — outbound WSS session to MIOSA;
                                                        registers itself as host_client in FrameRouter

  Started by `OptimalSystemAgent.Supervisors.Extensions` only when the
  `:open_computers_enabled` flag is `true`.
  """

  use Supervisor

  alias OptimalSystemAgent.OpenComputers.{Config, Executor, FrameRouter, Session, Updater}
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller, as: DesktopController
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Pty, as: PtyExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Tunnel, as: TunnelExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Controller, as: ClusterController

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Config,
      FrameRouter,
      Executor.Supervisor,
      PtyExecutor,
      DesktopController,
      TunnelExecutor,
      # Inference cluster controller — manages exo/MLX processes on this host
      ClusterController,
      Updater,
      Session
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
