defmodule OptimalSystemAgent.Supervisors.Extensions do
  @moduledoc """
  Subsystem supervisor for optional/extension processes.

  Opt-in children: treasury, OTA updater, OpenComputers (MIOSA control-plane
  connection). All sidecar, swarm, fleet, sandbox, wallet, and AMQP
  children removed from earlier iterations.
  """
  use Supervisor

  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      treasury_children() ++
      updater_children() ++
      open_computers_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Treasury — opt-in via OSA_TREASURY_ENABLED=true
  defp treasury_children do
    if Application.get_env(:optimal_system_agent, :treasury_enabled, false) do
      Logger.info("[Extensions] Treasury enabled — starting OptimalSystemAgent.Budget.Treasury")
      [OptimalSystemAgent.Budget.Treasury]
    else
      []
    end
  end

  # OTA updater — opt-in via OSA_UPDATE_ENABLED=true
  defp updater_children do
    if Application.get_env(:optimal_system_agent, :update_enabled, false) do
      Logger.info("[Extensions] OTA updater enabled — starting System.Updater")
      [OptimalSystemAgent.System.Updater]
    else
      []
    end
  end

  # OpenComputers — opt-in via OSA_OPEN_COMPUTERS_ENABLED=true
  # Connects this OSA installation to MIOSA's control plane so the host
  # appears in the MIOSA frontend as an orchestrable Computer.
  defp open_computers_children do
    if Application.get_env(:optimal_system_agent, :open_computers_enabled, false) do
      Logger.info("[Extensions] OpenComputers enabled — connecting to MIOSA control plane")
      [OptimalSystemAgent.OpenComputers.Supervisor]
    else
      []
    end
  end
end
