defmodule OptimalSystemAgent.Supervisors.Extensions do
  @moduledoc """
  Subsystem supervisor for optional/extension processes.

  Stripped to only: treasury (opt-in) and OTA updater (opt-in).
  All sidecar, swarm, fleet, sandbox, wallet, and AMQP children removed.
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
      receipt_children()

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

  # Receipt Chain — opt-in via RECEIPT_CHAIN_ENABLED=true
  defp receipt_children do
    if Application.get_env(:optimal_system_agent, :receipt_chain_enabled, false) do
      Logger.info("[Extensions] Receipt Emitter enabled — starting OptimalSystemAgent.Receipt.Emitter")
      [OptimalSystemAgent.Receipt.Emitter]
    else
      []
    end
  end

end
