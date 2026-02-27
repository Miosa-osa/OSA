defmodule OptimalSystemAgent.Fleet.Supervisor do
  @moduledoc """
  Top-level supervisor for the fleet management subsystem.

  Starts:
  - AgentRegistry (unique Registry for sentinel process lookup)
  - SentinelPool (DynamicSupervisor for per-agent sentinel GenServers)
  - Fleet.Registry (GenServer tracking all remote agents)
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: OptimalSystemAgent.Fleet.AgentRegistry},
      {DynamicSupervisor, name: OptimalSystemAgent.Fleet.SentinelPool, strategy: :one_for_one},
      OptimalSystemAgent.Fleet.Registry
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
