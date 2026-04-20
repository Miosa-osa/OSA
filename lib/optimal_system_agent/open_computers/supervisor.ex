defmodule OptimalSystemAgent.OpenComputers.Supervisor do
  @moduledoc """
  Extension supervisor for the OpenComputers subsystem.

  Children (all mandatory when the extension is enabled):

    * `OpenComputers.Config`             — TOML + env loader, cached via GenServer
    * `OpenComputers.Executor.Supervisor` — `DynamicSupervisor` for per-job processes
    * `OpenComputers.Session`             — outbound WSS session to MIOSA

  Started by `OptimalSystemAgent.Supervisors.Extensions` only when the
  `:open_computers_enabled` flag is `true`.
  """

  use Supervisor

  alias OptimalSystemAgent.OpenComputers.{Config, Executor, Session}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Config,
      Executor.Supervisor,
      Session
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
