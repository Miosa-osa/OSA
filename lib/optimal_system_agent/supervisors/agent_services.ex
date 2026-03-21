defmodule OptimalSystemAgent.Supervisors.AgentServices do
  @moduledoc """
  Subsystem supervisor for agent intelligence processes.

  Stripped to the minimal set needed for message/chat: memory, tasks,
  budget, progress, hooks, compactor, cortex, and scheduler.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      OptimalSystemAgent.Memory.Store,
      OptimalSystemAgent.Memory.Learning,
      OptimalSystemAgent.Agent.Memory.Episodic,
      OptimalSystemAgent.Agent.Tasks,
      OptimalSystemAgent.Budget,
      OptimalSystemAgent.Agent.Progress,
      OptimalSystemAgent.Agent.Hooks,
      OptimalSystemAgent.Agent.Scheduler,
      OptimalSystemAgent.Agent.Compactor,
      OptimalSystemAgent.Signal.Persistence,
      {DynamicSupervisor,
       name: OptimalSystemAgent.Verification.LoopSupervisor, strategy: :one_for_one},

      # Context Mesh — per-team context keepers with staleness tracking
      {Registry, keys: :unique, name: OptimalSystemAgent.ContextMesh.KeeperRegistry},
      OptimalSystemAgent.ContextMesh.Supervisor,
      OptimalSystemAgent.ContextMesh.Archiver,

      # Team Hierarchy — hierarchical team management with nervous system
      {Registry, keys: :unique, name: OptimalSystemAgent.Teams.Registry},
      OptimalSystemAgent.Teams.Supervisor,

      # Self-Healing — autonomous error diagnosis and repair
      OptimalSystemAgent.Healing.Orchestrator,

      # File Locking — region-level concurrent file editing
      OptimalSystemAgent.FileLocking.RegionLock,

      # Speculative Execution — agents work ahead on predicted tasks
      OptimalSystemAgent.Speculative.Executor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
