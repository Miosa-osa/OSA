defmodule OptimalSystemAgent.OpenComputers.Supervisor do
  @moduledoc """
  Supervises the OpenComputers agent-side processes:

    * `FrameRouter`      — routes frames between control plane and executors
    * `Desktop.Controller` — manages per-session VNC relay

  Started under `OptimalSystemAgent.Application` when
  `config :optimal_system_agent, :open_computers_enabled` is true (default).
  """

  use Supervisor

  alias OptimalSystemAgent.OpenComputers.{FrameRouter}
  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.Controller, as: DesktopController

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      FrameRouter,
      DesktopController
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
