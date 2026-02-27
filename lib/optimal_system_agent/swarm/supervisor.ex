defmodule OptimalSystemAgent.Swarm.Supervisor do
  @moduledoc """
  OTP Supervisor for the swarm subsystem.

  Supervision tree:
    - Mailbox           — ETS-backed inter-agent message store (GenServer)
    - Orchestrator      — Coordinates multi-agent task decomposition and execution
    - AgentPool         — DynamicSupervisor hosting transient Worker processes

  Strategy: :one_for_one — a crashed mailbox or orchestrator does not tear
  down the pool or vice versa; each component restarts independently.
  """
  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Swarm subsystem starting")

    children = [
      # Must start before Orchestrator so the ETS table is available
      OptimalSystemAgent.Swarm.Mailbox,
      OptimalSystemAgent.Swarm.Orchestrator,
      {DynamicSupervisor,
       name: OptimalSystemAgent.Swarm.AgentPool, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
