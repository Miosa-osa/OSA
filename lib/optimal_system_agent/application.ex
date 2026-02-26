defmodule OptimalSystemAgent.Application do
  @moduledoc """
  OTP Application supervisor for the Optimal System Agent.

  Supervision tree:
    - SessionRegistry (process registry for agent sessions)
    - PubSub (internal event fan-out — standalone, no Phoenix framework)
    - Events.Bus (goldrush-compiled :osa_event_router)
    - Bridge.PubSub (goldrush → PubSub bridge, 3 tiers)
    - Repo (SQLite3 persistent storage)
    - Providers.Registry (LLM provider routing via :osa_provider_router)
    - Skills.Registry (tool dispatch via :osa_tool_dispatcher)
    - Machines (composable skill set activation from ~/.osa/config.json)
    - OS.Registry (OS template discovery, connection, context injection)
    - MCP.Supervisor (MCP server/client processes)
    - Channels.Supervisor (platform adapters: CLI, Telegram, etc.)
    - Agent.Memory (persistent JSONL session storage)
    - Agent.Loop (stateful ReAct agent via :osa_agent_loop)
    - Agent.Scheduler (cron + heartbeat)
    - Agent.Compactor (context compression, 3 thresholds)
    - Agent.Cortex (memory synthesis, periodic knowledge bulletin)
    - Intelligence.Supervisor (Signal Theory unique modules)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Process registry for agent sessions
      {Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry},

      # Core infrastructure
      {Phoenix.PubSub, name: OptimalSystemAgent.PubSub},
      OptimalSystemAgent.Events.Bus,
      OptimalSystemAgent.Bridge.PubSub,
      OptimalSystemAgent.Store.Repo,

      # LLM providers (goldrush-compiled :osa_provider_router)
      OptimalSystemAgent.Providers.Registry,

      # Skills + machines (goldrush-compiled :osa_tool_dispatcher)
      OptimalSystemAgent.Skills.Registry,
      OptimalSystemAgent.Machines,

      # OS template discovery and connection
      OptimalSystemAgent.OS.Registry,

      # MCP integration
      {DynamicSupervisor, name: OptimalSystemAgent.MCP.Supervisor, strategy: :one_for_one},

      # Channel adapters
      {DynamicSupervisor, name: OptimalSystemAgent.Channels.Supervisor, strategy: :one_for_one},

      # Agent processes
      OptimalSystemAgent.Agent.Memory,
      OptimalSystemAgent.Agent.Scheduler,
      OptimalSystemAgent.Agent.Compactor,
      OptimalSystemAgent.Agent.Cortex,

      # Communication intelligence (Signal Theory unique)
      OptimalSystemAgent.Intelligence.Supervisor,

      # HTTP channel — Plug/Bandit on port 8089 (SDK API surface)
      # Started LAST so all agent processes are ready before accepting requests
      {Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: http_port()},
    ]

    opts = [strategy: :one_for_one, name: OptimalSystemAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_port do
    case System.get_env("OSA_HTTP_PORT") do
      nil -> Application.get_env(:optimal_system_agent, :http_port, 8089)
      port -> String.to_integer(port)
    end
  end
end
