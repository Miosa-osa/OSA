defmodule OptimalSystemAgent.Supervisors.Extensions do
  @moduledoc """
  Subsystem supervisor for optional/extension processes.

  Opt-in children: treasury, OTA updater, OpenComputers (MIOSA control-plane
  connection), FSCheckpoint (pre-operation filesystem snapshots). All sidecar,
  swarm, fleet, sandbox, wallet, and AMQP children removed from earlier
  iterations.
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
        open_computers_children() ++
        context_refs_children() ++
        fs_checkpoint_children() ++
        skin_engine_children() ++
        skill_curator_children()

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

  # ContextRefs — always enabled unless context_refs_enabled=false in settings.
  # Expands @file:, @diff, @staged, @git:N, @url: tokens in user messages.
  defp context_refs_children do
    if OptimalSystemAgent.Settings.get("context_refs_enabled", true) do
      Logger.info("[Extensions] ContextRefs enabled — registering @ref expansion hook")
      [OptimalSystemAgent.ContextRefs.Registrar]
    else
      []
    end
  end

  # FSCheckpoint — enabled by default, disable via settings key fs_checkpoints_enabled=false.
  # Snapshots files into a shadow git repo before destructive tool operations.
  defp fs_checkpoint_children do
    if OptimalSystemAgent.Settings.get("fs_checkpoints_enabled", true) do
      Logger.info("[Extensions] FSCheckpoint enabled — starting filesystem checkpoint server")
      [OptimalSystemAgent.FSCheckpoint.Server]
    else
      []
    end
  end

  # Skin engine — enabled by default, disable via settings key skin_engine_enabled=false.
  # Loads YAML skin definitions from priv/skins/ and ~/.osa/skins/, caches active skin.
  defp skin_engine_children do
    if OptimalSystemAgent.Settings.get("skin_engine_enabled", true) do
      Logger.info("[Extensions] Skin engine enabled — starting theme management")
      [OptimalSystemAgent.Skin.Engine]
    else
      []
    end
  end

  # Skill curator — enabled by default, disable via settings key skill_curator_enabled=false.
  # Periodically marks stale/archived skills based on usage data.
  defp skill_curator_children do
    if OptimalSystemAgent.Settings.get("skill_curator_enabled", true) do
      Logger.info("[Extensions] Skill curator enabled")
      [OptimalSystemAgent.Skills.Curator]
    else
      []
    end
  end
end
