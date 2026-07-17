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
      # 2000 children: supports ~10 parallel tool calls × 20 concurrent sessions
      # + bus event fan-out + SSE dispatch without hitting the limit under load.
      {Task.Supervisor, name: OptimalSystemAgent.Events.TaskSupervisor, max_children: 2000},

      # Core pub/sub and event routing
      {Phoenix.PubSub, name: OptimalSystemAgent.PubSub},
      OptimalSystemAgent.Events.Bus,
      OptimalSystemAgent.Events.DLQ,

      # Persistent storage
      OptimalSystemAgent.Store.Repo,

      # SSE event stream for frontend — must start after PubSub
      OptimalSystemAgent.EventStream,

      # Provider health / circuit breaker — must start before Registry
      OptimalSystemAgent.Providers.HealthChecker,

      # Model catalog (models.dev-style) — owns :osa_models_catalog ETS.
      # Started before Registry so context_window/available_models resolve
      # against it. Network refresh runs in the background (non-blocking).
      OptimalSystemAgent.Providers.Catalog,

      # LLM providers (goldrush-compiled :osa_provider_router)
      OptimalSystemAgent.Providers.Registry,

      # Tools (goldrush-compiled :osa_tool_dispatcher)
      OptimalSystemAgent.Tools.Registry,
      OptimalSystemAgent.Tools.Cache,
      OptimalSystemAgent.Machines,

      # Background shell mechanism — Registry for bg-id → worker lookup +
      # DynamicSupervisor for per-command supervised background processes
      # (shell_execute run_in_background + bash_output polling/kill).
      {Registry, keys: :unique, name: OptimalSystemAgent.Shell.BackgroundRegistry},
      {DynamicSupervisor,
       name: OptimalSystemAgent.Shell.BackgroundSupervisor, strategy: :one_for_one},

      # OS template discovery and connection
      OptimalSystemAgent.OS.Registry,

      # MCP integration — Registry for server name lookup + DynamicSupervisor for per-server GenServers
      {Registry, keys: :unique, name: OptimalSystemAgent.MCP.Registry},
      {DynamicSupervisor, name: OptimalSystemAgent.MCP.Supervisor, strategy: :one_for_one},

      # MCP client manager — reads ~/.osa/mcp.json, starts ServerSessions, and
      # owns the aggregate mcp_tools map in :persistent_term. Starts AFTER
      # Tools.Registry (so its persistent_term key exists) and after the MCP
      # Registry + Supervisor it starts children under.
      OptimalSystemAgent.MCP.Client.Manager,

      # Telemetry metrics (per-tool/per-provider execution stats)
      OptimalSystemAgent.Telemetry.Metrics,

      # API key rotation pool (reads ANTHROPIC_API_KEYS, OPENAI_API_KEYS, etc.)
      OptimalSystemAgent.Providers.CredentialPool
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
