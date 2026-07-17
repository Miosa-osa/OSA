defmodule OptimalSystemAgent.OpenComputers.Supervisor do
  @moduledoc """
  Extension supervisor for the OpenComputers subsystem.

  Children (started in order, strategy: one_for_one):

    * `OpenComputers.Config`                          — TOML + env loader, cached via GenServer
    * `OpenComputers.FrameRouter`                     — outbound frame fan-out to registered Session pid
    * `OpenComputers.Executor.Supervisor`             — DynamicSupervisor for per-job processes
    * `OpenComputers.Executor.Direct.Pty`             — long-lived PTY session manager
    * `OpenComputers.Executor.Direct.Desktop.Controller` — long-lived desktop relay manager
    * `OpenComputers.Executor.Direct.GhaRunner`       — GitHub Actions self-hosted runner manager
    * `OpenComputers.Executor.Direct.WgMesh`          — WireGuard mesh networking manager
    * `OpenComputers.Updater`                         — periodic self-update poller
    * `OpenComputers.Session`                         — outbound WSS session to MIOSA;
                                                        registers itself as host_client in FrameRouter

  Started by `OptimalSystemAgent.Supervisors.Extensions` only when the
  `:open_computers_enabled` flag is `true`.
  """

  use Supervisor
  require Logger

  alias OptimalSystemAgent.OpenComputers.{Config, Executor, FrameRouter, Session, Updater}
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller, as: DesktopController
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Pty, as: PtyExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Tunnel, as: TunnelExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Cluster.Controller, as: ClusterController
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.GhaRunner, as: GhaRunnerExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Backup, as: BackupExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.WgMesh, as: WgMeshExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Container, as: ContainerExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Compose, as: ComposeExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.SshKeys, as: SshKeysExecutor
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Clipboard, as: ClipboardExecutor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Config,
      FrameRouter,
      Executor.Supervisor
    ] ++ pty_children() ++ [
      DesktopController,
      TunnelExecutor,
      # Inference cluster controller — manages exo/MLX processes on this host
      ClusterController,
      # GitHub Actions self-hosted runner controller
      GhaRunnerExecutor,
      # Backup executor — handles backup_snapshot_request and backup_restore_request
      BackupExecutor,
      # WireGuard mesh networking — manages wg interfaces for tenant mesh networks
      WgMeshExecutor,
      # Container orchestration — Docker/Podman lifecycle, log streaming, stats
      ContainerExecutor,
      # Docker Compose multi-service stacks — up/down/ps/logs wrapping docker compose v2
      ComposeExecutor,
      # SSH key management — add/remove authorized_keys entries on this host
      SshKeysExecutor,
      # Clipboard sync — bidirectional clipboard relay (pbcopy/xclip/wl-copy)
      ClipboardExecutor,
      Updater,
      Session
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The PTY executor relies on :erlexec, whose native C port program does not
  # build on Windows (the dep is excluded from the win32 build entirely — see
  # mix.exs unix_only_deps/0). On Windows we skip starting this child so the
  # rest of the OpenComputers subsystem still runs; every other executor is
  # unaffected. On Unix (Linux/macOS) behavior is unchanged — PtyExecutor starts.
  defp pty_children do
    if match?({:win32, _}, :os.type()) do
      Logger.info("[OpenComputers] PTY/native exec disabled on Windows (erlexec unavailable)")
      []
    else
      [PtyExecutor]
    end
  end
end
