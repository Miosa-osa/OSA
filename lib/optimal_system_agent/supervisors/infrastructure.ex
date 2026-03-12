defmodule OptimalSystemAgent.Supervisors.Infrastructure do
  @moduledoc """
  Subsystem supervisor for core infrastructure processes.

  Manages the foundational layer that all other subsystems depend on:
  registries, pub/sub, event bus, storage, telemetry, provider/tool routing,
  machines, commands, OS templates, and MCP integration.

  Uses `:rest_for_one` because several children have strict ordering:
  - TaskSupervisor must start before Events.Bus (Bus spawns supervised tasks)
  - Events.Bus must start before Events.DLQ and Bridge.PubSub
  - Bridge.PubSub must start before Telemetry.Metrics
  - HealthChecker must start before Providers.Registry
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Process registry for agent sessions
      {Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry},

      # Task supervisor for supervised async work (must come before Events.Bus)
      {Task.Supervisor, name: OptimalSystemAgent.Events.TaskSupervisor, max_children: 100},

      # Core pub/sub and event routing
      {Phoenix.PubSub, name: OptimalSystemAgent.PubSub},
      OptimalSystemAgent.Events.Bus,
      OptimalSystemAgent.Events.DLQ,
      OptimalSystemAgent.Bridge.PubSub,

      # Persistent storage
      OptimalSystemAgent.Store.Repo,

      # SSE event stream for Command Center — must start after PubSub
      OptimalSystemAgent.EventStream,

      # Telemetry — subscribes to Events.Bus; must start after Bus + TaskSupervisor
      OptimalSystemAgent.Telemetry.Metrics,

      # Provider health / circuit breaker — must start before Registry
      MiosaLLM.HealthChecker,

      # LLM providers (goldrush-compiled :osa_provider_router)
      MiosaProviders.Registry,

      # Tools + machines (goldrush-compiled :osa_tool_dispatcher)
      OptimalSystemAgent.Tools.Registry,
      OptimalSystemAgent.Tools.Cache,
      OptimalSystemAgent.Machines,

      # Slash command registry (built-in + custom + agent-created)
      OptimalSystemAgent.Commands,

      # OS template discovery and connection
      OptimalSystemAgent.OS.Registry,

      # MCP integration — Registry for server name lookup + DynamicSupervisor for per-server GenServers
      {Registry, keys: :unique, name: OptimalSystemAgent.MCP.Registry},
      {DynamicSupervisor, name: OptimalSystemAgent.MCP.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
