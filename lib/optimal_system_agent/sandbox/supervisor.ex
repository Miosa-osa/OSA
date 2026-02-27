defmodule OptimalSystemAgent.Sandbox.Supervisor do
  @moduledoc """
  Supervisor for the Docker sandbox subsystem.

  Manages the lifecycle of sandbox infrastructure:
  - `Sandbox.Pool` — warm container pool (GenServer)

  This supervisor is only started when `sandbox_enabled: true` is set in
  config. See `OptimalSystemAgent.Application` for the conditional start.

  Strategy: `:one_for_one` — if the Pool crashes it restarts independently
  without disrupting other agent processes.
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Sandbox.Supervisor] Starting sandbox infrastructure")

    children = [
      OptimalSystemAgent.Sandbox.Pool
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
