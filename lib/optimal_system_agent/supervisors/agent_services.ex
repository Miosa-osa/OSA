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
      # Dream-memory — idle-gated background consolidation of recent sessions
      # into durable long-term memory (writes via Memory.Store).
      OptimalSystemAgent.Memory.Dream,
      OptimalSystemAgent.Agent.Memory.Episodic,
      OptimalSystemAgent.Agent.Tasks,
      OptimalSystemAgent.Budget,
      # Remembers the quota windows providers report on their own responses,
      # so `/usage` can show them without spending a request to re-read them.
      OptimalSystemAgent.Usage.RateLimits,
      OptimalSystemAgent.Agent.Hooks,
      OptimalSystemAgent.Agent.Scheduler,
      OptimalSystemAgent.Agent.Scheduler.HeartbeatExecutor,
      OptimalSystemAgent.Agent.LoopControl,
      OptimalSystemAgent.Agent.Compactor,
      OptimalSystemAgent.Signal.Persistence,
      {DynamicSupervisor,
       name: OptimalSystemAgent.Verification.LoopSupervisor, strategy: :one_for_one},

      # Context Mesh — per-team context keepers with staleness tracking
      {Registry, keys: :unique, name: OptimalSystemAgent.ContextMesh.KeeperRegistry},
      OptimalSystemAgent.ContextMesh.Supervisor,
      OptimalSystemAgent.ContextMesh.Archiver,

      # Team Hierarchy — hierarchical team management with nervous system.
      #
      # The registry MUST be named `OptimalSystemAgent.Registry`: that is the
      # name every `{:via, Registry, {...}}` tuple in `teams/manager.ex`,
      # `teams/nervous_system.ex`, `teams/cost_tracker.ex` and
      # `workspace/workspace.ex` registers and looks up under. It was previously
      # started as `OptimalSystemAgent.Teams.Registry`, which nothing referenced,
      # so `team_create` raised `unknown registry` on the first spawn.
      {Registry, keys: :unique, name: OptimalSystemAgent.Registry},
      OptimalSystemAgent.Teams.Supervisor,

      # Self-Healing — autonomous error diagnosis and repair
      OptimalSystemAgent.Healing.Orchestrator,

      # File Locking — region-level concurrent file editing
      OptimalSystemAgent.FileLocking.RegionLock,

      # Speculative Execution — agents work ahead on predicted tasks
      OptimalSystemAgent.Speculative.Executor
    ]

    children
    |> OptimalSystemAgent.Supervisors.BootTiming.wrap("AgentServices")
    |> Supervisor.init(strategy: :one_for_one)
  end
end
